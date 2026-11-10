#include <Windows.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <charconv>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iomanip>
#include <limits>
#include <map>
#include <mutex>
#include <set>
#include <sstream>
#include <string_view>
#include "PluginAPI.h"

namespace {
using U = std::uint32_t;
using P = void*;
using Addr = std::uintptr_t;
constexpr U runtime = 0x12000690;
constexpr U feature_compass=1, feature_topic_catalog=2, feature_saved_area=4, feature_guest_torch=8;
constexpr Addr console_entry = 0x08FC21F0, console_original = 0x06A0C2B0;
constexpr Addr form_rtti = 0x08FE4BC8;
Addr image;
bool ready;
std::atomic<U> skipped_actor_candidates{0};
std::atomic<U> controlled_torch_actor{0};

template<class T> T game(Addr rva) { return reinterpret_cast<T>(image+rva); }
template<class T> T get(const void* object, size_t offset) {
    T value{};
    if (object) std::memcpy(&value, static_cast<const char*>(object)+offset, sizeof value);
    return value;
}
U id(P form) { return get<U>(form,0x10); }
unsigned type(P form) { return get<unsigned char>(form,8); }
P find(U form) { return game<P(*)(U)>(0x066114B0)(form); }
P as(P form, Addr to, Addr from=form_rtti) {
    return form ? game<P(*)(P,U,P,P,U)>(0x06BFC4D6)(form,0,game<P>(from),game<P>(to),0) : nullptr;
}
P cell(P ref) { return get<P>(ref,0x80); }
unsigned state(P area) { return get<unsigned char>(area,0x7B); }
bool interior(P area) { return (get<unsigned char>(area,0x79)&1)!=0; }
bool attached(P area) { return state(area)==5 || state(area)==6; }
bool paired(P ref) { return get<bool>(ref,0x40); }
bool dead(P actor) {
    if(type(actor)!=0x32) return false;
    const auto vtable=get<P>(actor,0);
    // The stock GetDead command checks the actor and then its life state.
    return get<bool(*)(P)>(vtable,0x350)(actor) && get<bool(*)(P,bool)>(vtable,0x360)(actor,true);
}
bool block_stock_death_load() {
    P player=get<P>(game<P>(0x0941F708),0);
    if(!player || player!=find(0x14) || !dead(player)) return false;
    // The game's own pairing handler cancels the armed reload timer.
    game<void(*)()>(0x0656DC90)();
    return true;
}
void evaluate_torch(P actor) {
    const U local=controlled_torch_actor.load(std::memory_order_relaxed);
    if(local && actor && id(actor)==local) return;
    game<void(*)(P)>(0x065CFA40)(actor);
}
bool scanned_actor_dead(P actor,bool include_unconscious) {
    using Predicate=bool(*)(P,bool);
    Predicate check=nullptr;
    // A background cell transition can leave a freed actor in this scan.
    // Validate the dispatch target before invoking the game's predicate.
    __try {
        if(actor) check=get<Predicate>(get<P>(actor,0),0x360);
    } __except(EXCEPTION_EXECUTE_HANDLER) {
        check=nullptr;
    }
    const auto address=reinterpret_cast<Addr>(check);
    if(address>=image+0x1000 && address<image+0x06D94AD7) return check(actor,include_unconscious);
    MEMORY_BASIC_INFORMATION memory{};
    if(check && VirtualQuery(reinterpret_cast<P>(check),&memory,sizeof memory) && memory.State==MEM_COMMIT
        && !(memory.Protect&PAGE_GUARD)
        && (memory.Protect&(PAGE_EXECUTE|PAGE_EXECUTE_READ|PAGE_EXECUTE_READWRITE|PAGE_EXECUTE_WRITECOPY))) {
        return check(actor,include_unconscious);
    }
    skipped_actor_candidates.fetch_add(1,std::memory_order_relaxed);
    return false;
}
P base_form(P ref) {
    return get<P(*)(P)>(get<P>(ref,0),0x62*sizeof(P))(ref);
}
struct Vec { float x,y,z; };
Vec position(P ref) { return get<Vec>(ref,0x64); }
Vec difference(Vec a,Vec b) { return {a.x-b.x,a.y-b.y,a.z-b.z}; }
const char* yes(bool value) { return value ? "true" : "false"; }
void point(std::ostream& out,const char* key,Vec v) {
    if (std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z))
        out << ",\"" << key << "\":[" << v.x << ',' << v.y << ',' << v.z << ']';
}
void cell_state(std::ostream& out,P area) {
    if (!area) { out << "null"; return; }
    out << "{\"state\":" << state(area) << ",\"attached\":" << yes(attached(area))
        << ",\"interior\":" << yes(interior(area)) << ",\"has_native_root\":" << yes(get<P>(area,0xD0)!=nullptr)
        << ",\"paired\":" << yes(get<bool>(area,0x50)) << '}';
}
struct ExtraLock {
    CRITICAL_SECTION* lock=game<CRITICAL_SECTION*>(0x0947FF00);
    ExtraLock() { EnterCriticalSection(lock); }
    ~ExtraLock() { LeaveCriticalSection(lock); }
};
P extra_list(P ref) { return ref ? static_cast<char*>(ref)+0x88 : nullptr; }
P extra(P list,unsigned kind) {
    if (!(get<unsigned char>(list,0x10+kind/8)&(1u<<(kind%8)))) return nullptr;
    unsigned remaining=2048;
    for(P e=get<P>(list,8); e && remaining--; e=get<P>(e,0x10))
        if (get<unsigned char>(e,8)==kind) return e;
    return nullptr;
}
using Records=std::map<U,std::string>;
Records positions,doors,dialogues,inventories,compasses;
std::mutex records_mutex;
bool save(Records& records,U key,const std::ostringstream& json) {
    std::lock_guard lock(records_mutex);
    if (records.size()>=256 && !records.count(key)) records.erase(records.begin());
    records[key]=json.str();
    return true;
}
size_t copy(const Records& records,U key,char* out,size_t cap) {
    std::lock_guard lock(records_mutex);
    const auto it=records.find(key);
    if (it==records.end()) return 0;
    const size_t need=it->second.size()+1;
    if (out && cap>=need) std::memcpy(out,it->second.c_str(),need);
    return need;
}
void header(std::ostream& out,U ref,U request) {
    out << std::setprecision(std::numeric_limits<float>::max_digits10)
        << "{\"schema\":1,\"actor_ref\":" << ref << ",\"request\":" << request;
}
void actor_guid(std::ostream& out,const char* key,P ref);
bool actor_position(U ref,U request) {
    P actor=find(ref);
    if(type(actor)!=0x32) return false;
    P area=cell(actor);
    std::ostringstream out;
    header(out,ref,request);
    out << ",\"cell_ref\":" << id(area) << ",\"interior\":" << yes(interior(area))
        << ",\"dead\":" << yes(dead(actor))
        << ",\"skipped_actor_candidates\":" << skipped_actor_candidates.load(std::memory_order_relaxed)
        << ",\"actor_paired\":" << yes(paired(actor))
        << ",\"actor_has_pairing_entry\":" << yes(get<P>(actor,0x48)!=nullptr) << ",\"cell\":";
    cell_state(out,area);
    point(out,"native_position",position(actor));
    if(attached(area) && interior(area)) {
        out << ",\"doors\":[";
        unsigned remaining=8192,emitted=0;
        ExtraLock lock;
        for(P node=static_cast<char*>(area)+0xB8; node && remaining-- && emitted<128; node=get<P>(node,8)) {
            P door_ref=get<P>(node,0);
            if(type(door_ref)!=0x31 || type(base_form(door_ref))!=0x18) continue;
            if(emitted++) out << ',';
            out << "{\"ref\":" << id(door_ref);
            actor_guid(out,"guid",door_ref);
            out << '}';
        }
        out << ']';
    }
    out << '}';
    return save(positions,ref,out);
}
void actor_guid(std::ostream& out,const char* key,P ref) {
    P guid=extra(extra_list(ref),0x5E);
    if(!guid) return;
    out << ",\"" << key << "\":[";
    for(size_t i=0;i<4;++i) {
        if(i) out << ',';
        out << get<std::int32_t>(guid,0x18+i*4);
    }
    out << ']';
}
bool door(U ref,U request) {
    P actor=find(ref);
    P base=type(actor)==0x31 ? base_form(actor) : nullptr;
    std::ostringstream out;
    header(out,ref,request);
    if(type(base)!=0x18) {
        out << ",\"error\":\"" << (actor ? "not_a_door" : "reference_unavailable") << "\"}";
        return save(doors,ref,out);
    }
    out << ",\"guest_attached_transfer\":true";
    if(ref==0x2C3AC || ref==0x2B092) out << ",\"guest_hotel_travel\":true";
    ExtraLock lock;
    P list=extra_list(actor);
    P teleport=as(extra(list,0x32),0x08FE5150,0x08FE5128);
    P data=get<P>(teleport,0x18);
    P target=get<P>(data,0);
    P source=cell(actor), dest=cell(target);
    P script=as(base,0x08FE50A0);
    out << ",\"cell_ref\":" << id(source) << ",\"door\":{\"has_teleport\":" << yes(teleport!=nullptr)
        << ",\"destination_ref\":" << id(target) << ",\"destination_cell\":" << id(dest)
        << ",\"source_paired\":" << yes(paired(actor)) << ",\"destination_paired\":" << yes(paired(target))
        << ",\"has_lock_data\":" << yes(extra(list,0x31) || extra(extra_list(target),0x31))
        << ",\"has_script\":" << yes(get<P>(script,8) || extra(list,0x12))
        << ",\"has_random_destination\":" << yes(extra(list,0x43)!=nullptr) << ",\"source_cell\":";
    cell_state(out,source);
    out << ",\"target_cell\":";
    cell_state(out,dest);
    actor_guid(out,"source_guid",actor);
    actor_guid(out,"destination_guid",target);
    if(target) {
        const auto arrival=get<Vec>(data,8);
        point(out,"source_position",position(actor));
        point(out,"arrival",arrival);
        point(out,"arrival_rotation",get<Vec>(data,0x14));
        point(out,"destination_rotation",get<Vec>(target,0x58));
        point(out,"arrival_offset",difference(arrival,position(target)));
    }
    out << "}}";
    return save(doors,ref,out);
}

using CellCallback=void(*)(P,bool,bool,const void*,const void*,const void*,U);
thread_local U preparing_cell;
thread_local bool skipped_cell_reload;
void keep_world(P,bool,bool,const void*,const void*,const void*,U) {}
void queue_cell(P queue,P pairing,U frame,const char* name,CellCallback callback,
                bool seamless,bool fade,const void* level,const void* world,const void* name2,U area) {
    if (preparing_cell && area==preparing_cell && !seamless && !fade && callback==game<CellCallback>(0x04704980)) {
        callback=keep_world;
        skipped_cell_reload=true;
    }
    game<decltype(&queue_cell)>(0x06654230)(queue,pairing,frame,name,callback,seamless,fade,level,world,name2,area);
}
bool prepare(U area,U step) {
    if (step!=2 && step!=3) return false;
    P host=find(0x14);
    if(type(host)!=0x32) return false;
    P primary=cell(host);
    if(state(primary)!=6) return false;
    P target=find(area);
    if(type(target)!=0x30 || target==primary || !interior(target)) return false;
    const auto current=state(target);
    const auto root=get<P>(target,0xD0);
    const auto paired_cell=get<bool>(target,0x50);
    if(step==2 && !current && !root && !paired_cell) {
        skipped_cell_reload=false;
        preparing_cell=area;
        const auto result=game<P(*)(P)>(0x0665DF10)(target);
        preparing_cell=0;
        return result && result==get<P>(target,0xD0) && state(target)==3 && skipped_cell_reload;
    }
    if(step==3 && current==3 && root && paired_cell) {
        const auto manager=get<P>(game<P>(0x0941F748),0);
        const auto parent=get<P>(manager,0x10);
        const auto active=get<P>(manager,0x50);
        if(!parent || (active && active!=primary)) return false;
        game<void(*)(P,P)>(0x06657540)(target,parent);
        if(state(target)!=5) return false;
        game<void(*)(P,unsigned char)>(0x066564D0)(target,1);
        return state(target)==6;
    }
    return false;
}

bool cross_door(U guest_id,U source_id,U target_id,U landing=0) {
    if((guest_id>>24)!=0xFF || source_id==target_id || landing>4) return false;
    P guest=find(guest_id), source=find(source_id), target=find(target_id);
    if(type(guest)!=0x32 || dead(guest) || type(source)!=0x31 || type(target)!=0x31) return false;
    P origin=cell(guest), from=cell(source), to=cell(target);
    if(!attached(origin) || !attached(from) || !attached(to)
        || !paired(guest) || !get<P>(guest,0x48) || !paired(source) || !paired(target)) return false;
    if(origin!=from && (interior(origin) || interior(from)
        || !get<P>(origin,0xC8) || get<P>(origin,0xC8)!=get<P>(from,0xC8))) return false;
    const auto delta=difference(position(guest),position(source));
    if(delta.x*delta.x+delta.y*delta.y+delta.z*delta.z>400.0f*400.0f) return false;
    Vec arrival{}, rotation{};
    {
        ExtraLock lock;
        for(P door_ref:{source,target}) {
            P base=base_form(door_ref);
            if(type(base)!=0x18 || get<P>(as(base,0x08FE50A0),8)
                || extra(extra_list(door_ref),0x31) || extra(extra_list(door_ref),0x12)
                || extra(extra_list(door_ref),0x43)) return false;
        }
        P data=get<P>(as(extra(extra_list(source),0x32),0x08FE5150,0x08FE5128),0x18);
        if(get<P>(data,0)!=target) return false;
        arrival=get<Vec>(data,8);
        rotation=get<Vec>(data,0x14);
    }
    if(!std::isfinite(arrival.x) || !std::isfinite(arrival.y) || !std::isfinite(arrival.z)
        || !std::isfinite(rotation.x) || !std::isfinite(rotation.y) || !std::isfinite(rotation.z)) return false;
    // Lua checks collision before selecting one of these bounded alternatives.
    if(landing==1) arrival.x+=90;
    else if(landing==2) arrival.x-=90;
    else if(landing==3) arrival.y+=90;
    else if(landing==4) arrival.y-=90;
    game<void(*)(P,const Vec*)>(0x0658C620)(guest,&arrival);
    game<void(*)(P,const Vec*)>(0x0658BE30)(guest,&rotation);
    game<void(*)(P,P,P)>(0x06585530)(guest,to,interior(to) ? nullptr : get<P>(to,0xC8));
    return cell(guest)==to;
}

struct Landing { double x,y,z; };
std::mutex transform_mutex;
Addr held;
ULONGLONG deadline;
bool check_landing;
Landing landing;
U accepted,rejected,suppressed;
void transform(P component,const void* value,bool teleport) {
    {
        std::lock_guard lock(transform_mutex);
        if (held && held==reinterpret_cast<Addr>(component) && GetTickCount64()<deadline) {
            bool accept=false;
            if (check_landing && value) {
                const auto p=get<Landing>(value,0x20);
                const auto x=p.x-landing.x,y=p.y-landing.y,z=p.z-landing.z;
                accept=x*x+y*y+z*z<240.0*240.0;
                ++(accept ? accepted : rejected);
            }
            if (!accept) { ++suppressed; return; }
        }
    }
    game<decltype(&transform)>(0x048CCC90)(component,value,teleport);
}

bool guest_in_range(P speaker,P listener) {
    P a=cell(speaker), b=cell(listener);
    if(!attached(a) || !attached(b)) return false;
    if(a!=b && (interior(a) || interior(b) || !get<P>(a,0xC8) || get<P>(a,0xC8)!=get<P>(b,0xC8))) return false;
    const auto d=difference(position(speaker),position(listener));
    return d.x*d.x+d.y*d.y+d.z*d.z<=320.0f*320.0f;
}
bool known_topic(U topic_id) {
    if(topic_id==0xC8 || topic_id==0xD4) return true;
    P player=find(0x14);
    if(type(player)!=0x32) return false;
    unsigned remaining=8192;
    for(P node=static_cast<char*>(player)+0x890;node && remaining--;node=get<P>(node,8)) {
        P topic=get<P>(node,0);
        if(type(topic)==0x39 && id(topic)==topic_id) return true;
    }
    return false;
}
void quoted(std::ostream& out,std::string_view value);
std::string_view component_string(P component);
U current_speaker() {
    P tile=game<P(*)(U)>(0x066F1F80)(0x3F1);
    P menu=tile ? game<P(*)(P)>(0x066F1F30)(tile) : nullptr;
    if(get<P>(menu,0)!=game<P>(0x0863E548)) return 0;
    P actor=get<P>(menu,0xC0);
    return type(actor)==0x32 ? id(actor) : 0;
}
bool dialogue(U request,U speaker_id,U listener_id,U topic_id,bool scoped) {
    std::ostringstream out;
    out << "{\"schema\":1,\"request\":" << request << ",\"speaker_ref\":" << (scoped ? speaker_id : current_speaker());
    if(!scoped) {
        out << ",\"guest_read_only\":true,\"topic_catalog\":true}";
        return save(dialogues,request,out);
    }
    if(speaker_id==0x14 || speaker_id==listener_id || (listener_id!=0x14 && (listener_id>>24)!=0xFF)) return false;
    P speaker=find(speaker_id), listener=find(listener_id), topic=find(topic_id);
    const auto valid=[](P actor) { return type(actor)==0x32 && cell(actor) && paired(actor) && get<P>(actor,0x48); };
    if(!valid(speaker) || !valid(listener)) return false;
    if(!topic_id) {
        out << ",\"listener_ref\":" << listener_id << ",\"topic_ref\":0,\"topics\":[";
        std::set<U> topics{0xC8,0xD4};
        P player=find(0x14);
        unsigned remaining=8192;
        for(P node=player ? static_cast<char*>(player)+0x890 : nullptr;node && remaining--;node=get<P>(node,8)) {
            P item=get<P>(node,0);
            if(type(item)==0x39 && !(get<U>(item,0xC)&0x20)) topics.insert(id(item));
        }
        bool first=true;
        if(guest_in_range(speaker,listener)) for(U value:topics) {
            P item=find(value);
            if(type(item)!=0x39) continue;
            if(!first) out << ',';
            first=false;
            out << "{\"ref\":" << value << ",\"name\":";
            quoted(out,component_string(as(item,0x08FE4D40)));
            out << '}';
        }
        out << "]}";
        return save(dialogues,request,out);
    }
    if(type(topic)!=0x39 || (get<U>(topic,0xC)&0x20)) return false;
    out << ",\"listener_ref\":" << listener_id << ",\"topic_ref\":" << topic_id << ",\"choices\":[";
    if(known_topic(topic_id) && guest_in_range(speaker,listener)) {
        unsigned emitted=0, visited=0;
        for(P node=static_cast<char*>(topic)+0x50; node && visited++<128 && emitted<64; node=get<P>(node,8)) {
            P entry=get<P>(node,0), quest=get<P>(entry,0);
            const auto infos=get<P*>(entry,0x10);
            const auto count=get<U>(entry,0x1C);
            if(type(quest)!=0x3B || !(get<unsigned char>(quest,0x78)&1) || !infos || count>4096) continue;
            for(U i=0;i<count && emitted<64;++i) {
                P info=infos[i];
                bool alternate=false;
                if(type(info)!=0x3A || !game<bool(*)(P,bool*,P,P,P)>(0x06825640)(info,&alternate,quest,speaker,listener)) continue;
                if(emitted++) out << ',';
                out << "{\"info_ref\":" << id(info) << ",\"quest_ref\":" << id(quest) << '}';
            }
        }
    }
    out << "]}";
    return save(dialogues,request,out);
}

void quoted(std::ostream& out,std::string_view value) {
    out << '"';
    for(unsigned char c:value) {
        if(c=='"' || c=='\\') out << '\\' << char(c);
        else if(c<32) { const char* hex="0123456789abcdef"; out << "\\u00" << hex[c>>4] << hex[c&15]; }
        else out << char(c);
    }
    out << '"';
}
std::string_view component_string(P component) {
    const auto value=get<const char*>(component,8);
    const auto size=get<std::uint16_t>(component,0x10);
    return value && size<4096 ? std::string_view(value,size) : std::string_view();
}
void icon(std::ostream& out,P component) {
    const auto name=component_string(component);
    if(!name.empty()) { out << ",\"icon_path\":"; quoted(out,name); }
}
std::set<U> map_markers;
P catalog_buckets;
U catalog_bucket,catalog_size;
bool index_map_markers() {
    const P table=game<P>(0x08FAB540);
    const auto buckets=get<P*>(table,0x10);
    const U size=get<U>(table,8);
    if(!buckets || !size || size>0x1000000) return false;
    if(catalog_buckets!=buckets || catalog_size!=size) {
        catalog_buckets=buckets; catalog_size=size; catalog_bucket=0;
        map_markers.clear();
    }
    const U stop=std::min(size,catalog_bucket+4096);
    ExtraLock lock;
    for(;catalog_bucket<stop;++catalog_bucket) {
        unsigned remaining=8192;
        for(P node=buckets[catalog_bucket];node && remaining--;node=get<P>(node,0)) {
            P form=get<P>(node,0x10);
            if(type(form)==0x31 && !(get<U>(form,0xC)&0x20) && extra(extra_list(form),0x33)) {
                map_markers.insert(id(form));
            }
        }
    }
    return catalog_bucket==size;
}
P map_world(P world) {
    for(unsigned depth=0;world && depth<16;++depth) {
        if(type(world)!=0x35) return nullptr;
        P parent=get<P>(world,0xF8);
        if(!parent) return world;
        world=parent;
    }
    return nullptr;
}
double numeric_setting(const char* name,double fallback) {
    P table=game<P>(0x08FAF738);
    P vtable=get<P>(table,0);
    if(!vtable || !name || (name[0]!='i' && name[0]!='f')) return fallback;
    const auto bucket=get<U(*)(P,const char*)>(vtable,8)(table,name);
    const auto size=get<U>(table,8);
    const auto buckets=get<P*>(table,0x10);
    if(!buckets || bucket>=size) return fallback;
    unsigned remaining=8192;
    for(P node=buckets[bucket];node && remaining--;node=get<P>(node,0)) {
        const auto key=get<const char*>(node,8);
        if(key && get<bool(*)(P,const char*,const char*)>(vtable,0x10)(table,name,key)) {
            P setting=get<P>(node,0x10);
            if(!setting) return fallback;
            const double value=name[0]=='i' ? get<std::int32_t>(setting,0) : get<float>(setting,0);
            return std::isfinite(value) ? value : fallback;
        }
    }
    return fallback;
}
bool compass(U ref,U request) {
    P actor=find(ref);
    if(type(actor)!=0x32 || !attached(cell(actor))) return false;
    const bool indexed=index_map_markers();
    std::ostringstream out;
    header(out,ref,request);
    out << ",\"indexed\":" << yes(indexed) << ",\"cell_ref\":" << id(cell(actor)) << ",\"markers\":[";
    bool first=true;
    const double range=std::max(0.0,numeric_setting("iMapMarkerVisibleDistance",12000));
    P world=interior(cell(actor)) ? nullptr : map_world(get<P>(cell(actor),0xC8));
    if(world) {
        ExtraLock lock;
        for(U marker_id:map_markers) {
            P marker=find(marker_id);
            if(type(marker)!=0x31 || map_world(game<P(*)(P)>(0x06580940)(marker))!=world) continue;
            P data=get<P>(extra(extra_list(marker),0x33),0x18);
            if(!data) continue;
            const Vec delta=difference(position(marker),position(actor));
            const double distance=std::sqrt(double(delta.x)*delta.x+double(delta.y)*delta.y+double(delta.z)*delta.z);
            if(!std::isfinite(distance) || distance>range) continue;
            if(!first) out << ',';
            first=false;
            double angle=std::atan2(delta.x,delta.y)*180.0/3.14159265358979323846;
            if(angle<0) angle+=360;
            out << "{\"ref\":" << marker_id << ",\"name\":";
            quoted(out,component_string(data));
            out << ",\"angle\":" << angle << ",\"distance\":" << distance
                << ",\"type\":" << get<std::uint16_t>(data,0x1A)
                << ",\"flags\":" << unsigned(get<unsigned char>(data,0x18)) << '}';
        }
    }
    out << "]}";
    return save(compasses,ref,out);
}
bool inventory(U ref,U request) {
    P actor=find(ref);
    if(type(actor)!=0x32) return false;
    struct Item { P form{}; std::int64_t count{}; bool worn{},left{},health_set{}; float health=-1; };
    std::map<U,Item> items;
    std::ostringstream out;
    header(out,ref,request);
    out << ",\"cell_ref\":" << id(cell(actor));
    point(out,"native_position",position(actor));
    out << ",\"items\":[";
    ExtraLock lock;
    P base=base_form(actor), container=as(base,0x08FE61B0);
    unsigned remaining=8192;
    for(P node=container ? static_cast<char*>(container)+0x10 : nullptr; node && remaining--; node=get<P>(node,8)) {
        P entry=get<P>(node,0), form=get<P>(entry,8);
        if(!form || as(form,0x08FE6200)) continue;
        auto& item=items[id(form)];
        item.form=form; item.count+=get<std::int32_t>(entry,0);
    }
    P changes=get<P>(extra(extra_list(actor),0x1A),0x18);
    remaining=8192;
    for(P node=get<P>(changes,0); node && remaining--; node=get<P>(node,8)) {
        P entry=get<P>(node,0), form=get<P>(entry,0x10);
        if(!form) continue;
        auto& item=items[id(form)];
        item.form=form; item.count+=get<std::int32_t>(entry,8);
        unsigned stacks=8192;
        for(P stack=get<P>(entry,0); stack && stacks--; stack=get<P>(stack,8)) {
            P list=get<P>(stack,0);
            const bool left=extra(list,0x1C)!=nullptr, worn=left || extra(list,0x1B);
            P health=as(extra(list,0x2B),0x08FE6980,0x08FE5128);
            item.left|=left; item.worn|=worn;
            if(worn || (!item.health_set && health)) {
                const auto n=get<float>(health,0x18);
                item.health=health && std::isfinite(n) ? n : -1;
                item.health_set=true;
            }
        }
    }
    bool first=true;
    for(const auto& entry:items) {
        const auto& item=entry.second;
        if(item.count<=0) continue;
        if(!first) out << ',';
        first=false;
        out << "{\"form_id\":" << entry.first << ",\"type\":" << type(item.form) << ",\"count\":" << item.count
            << ",\"equipped\":" << yes(item.worn) << ",\"left\":" << yes(item.left) << ",\"name\":";
        quoted(out,component_string(as(item.form,0x08FE4D40)));
        const auto weight=get<float>(as(item.form,0x08FE5960),8);
        out << ",\"weight\":" << (std::isfinite(weight) ? weight : 0) << ",\"value\":" << get<U>(as(item.form,0x08FE5938),8);
        icon(out,as(item.form,0x08FE6118));
        const auto max_health=get<U>(as(item.form,0x08FE52F0),8);
        if(max_health) out << ",\"health\":" << (item.health<0 ? 100.0 : 100.0*item.health/max_health)
                          << ",\"max_health\":" << max_health;
        out << '}';
    }
    out << "],\"spells\":[";
    P spells=as(base,0x08FF4DB0);
    remaining=1024; first=true;
    for(P node=spells ? static_cast<char*>(spells)+8 : nullptr; node && remaining--; node=get<P>(node,8)) {
        P spell=get<P>(node,0);
        if(type(spell)!=0x10 || get<U>(spell,0x90)) continue;
        P effect=get<P>(spell,0x50);
        const auto range=get<U>(effect,0x18);
        if(!effect || range>2) continue;
        if(!first) out << ',';
        first=false;
        out << "{\"form_id\":" << id(spell) << ",\"range\":" << range << ",\"name\":";
        quoted(out,component_string(as(spell,0x08FE4D40)));
        icon(out,as(get<P>(effect,0x28),0x08FE6118,0x08FE6138));
        out << '}';
    }
    out << "]}";
    return save(inventories,ref,out);
}

using Command=bool(*)(const void*,const char*,P,P,P,P,double*,U*);
using Extract=bool(*)(const void*,const char*,U*,P,P,P,P,...);
bool route(std::string_view packet) {
    if(packet.size()<3 || packet[1]!=':') return false;
    const char op=packet[0];
    packet.remove_prefix(2);
    std::array<U,4> args{};
    size_t count=0;
    while(!packet.empty()) {
        if(count==args.size()) return false;
        const auto end=packet.find(':');
        const auto field=packet.substr(0,end);
        const auto parsed=std::from_chars(field.data(),field.data()+field.size(),args[count++]);
        if(parsed.ec!=std::errc() || parsed.ptr!=field.data()+field.size()) return false;
        if(end==std::string_view::npos) break;
        packet.remove_prefix(end+1);
        if(packet.empty()) return false;
    }
    switch(op) {
        case 'b': return count==1 && args[0]==1 && block_stock_death_load();
        case 'c': return (count==3 || count==4) && cross_door(args[0],args[1],args[2],args[3]);
        case 'm': return count==2 && compass(args[0],args[1]);
        case 'p': return count==2 && actor_position(args[0],args[1]);
        case 'i': return count==2 && inventory(args[0],args[1]);
        case 'd': return count==2 && door(args[0],args[1]);
        case 'h': return count==2 && prepare(args[0],args[1]);
        case 't': return (count==1 || count==4) && dialogue(args[0],args[1],args[2],args[3],count==4);
        default: return false;
    }
}
bool bridge(const void* params,const char* data,P ref,P containing,P script,P locals,double* result,U* offset) {
    // Preserve stock command semantics for any non-LSS setting. Inspect the
    // compiled string using the original argument reader and a separate cursor.
    constexpr std::string_view prefix="LSS2:";
    if(ready && result && offset) {
        U end=*offset;
        thread_local std::array<char,65536> buffer{};
        buffer[0]='\0';
        if(game<Extract>(0x06630750)(params,data,&end,ref,containing,script,locals,buffer.data())
            && std::string_view(buffer.data(),prefix.size())==prefix) {
            *offset=end;
            try { *result=route(buffer.data()+prefix.size()) ? 1 : 0; }
            catch(...) { *result=0; }
            return true;
        }
    }
    return game<Command>(console_original)(params,data,ref,containing,script,locals,result,offset);
}
bool write(void* target,const void* data,size_t size) {
    DWORD old=0;
    if(!VirtualProtect(target,size,PAGE_EXECUTE_READWRITE,&old)) return false;
    std::memcpy(target,data,size);
    FlushInstructionCache(GetCurrentProcess(),target,size);
    VirtualProtect(target,size,old,&old);
    return true;
}
struct CallPatch { Addr site,original; Addr hook; size_t length; std::array<unsigned char,6> before,after; };
bool install(const OBSEInterface* obse) {
    auto* entry=game<char*>(console_entry);
    const auto name=get<const char*>(entry,0);
    const auto params=get<P>(entry,0x28);
    if(!name || std::strcmp(name,"GetINISetting") || get<std::uint16_t>(entry,0x22)!=1
        || params!=game<P>(0x08FB89D0) || get<U>(params,8)!=0 || get<Addr>(entry,0x30)!=image+console_original) return false;
    auto* api=static_cast<OBSETrampolineInterface*>(obse->QueryInterface(kInterface_Trampoline));
    if(!api || api->interfaceVersion<1 || !api->AllocateFromBranchPool) return false;
    std::array<CallPatch,5> patches{{
        {0x048B97C2,0x048CCC90,reinterpret_cast<Addr>(&transform),5,{},{}},
        {0x048D1A5B,0x048CCC90,reinterpret_cast<Addr>(&transform),5,{},{}},
        {0x0665FC8C,0x06654230,reinterpret_cast<Addr>(&queue_cell),5,{},{}},
        {0x06680F90,0,reinterpret_cast<Addr>(&scanned_actor_dead),6,{},{}},
        {0x066A55D4,0x065CFA40,reinterpret_cast<Addr>(&evaluate_torch),5,{},{}},
    }};
    for(auto& patch:patches) {
        auto* site=game<char*>(patch.site);
        if(patch.original) {
            if(get<unsigned char>(site,0)!=0xE8 || patch.site+5+get<std::int32_t>(site,1)!=patch.original) return false;
        } else {
            constexpr unsigned char virtual_call[]={0xFF,0x90,0x60,0x03,0,0};
            if(std::memcmp(site,virtual_call,sizeof virtual_call)) return false;
        }
        std::memcpy(patch.before.data(),site,patch.length);
    }
    auto* stubs=static_cast<unsigned char*>(api->AllocateFromBranchPool(obse->GetPluginHandle(),patches.size()*16));
    if(!stubs) return false;
    for(size_t i=0;i<patches.size();++i) {
        auto& patch=patches[i];
        auto* stub=stubs+i*16;
        const auto delta=reinterpret_cast<std::intptr_t>(stub)-static_cast<std::intptr_t>(image+patch.site+5);
        if(delta<std::numeric_limits<std::int32_t>::min() || delta>std::numeric_limits<std::int32_t>::max()) return false;
        const unsigned char jump[]={0xFF,0x25,0,0,0,0};
        std::memcpy(stub,jump,sizeof jump);
        std::memcpy(stub+sizeof jump,&patch.hook,sizeof patch.hook);
        patch.after[0]=0xE8;
        patch.after[5]=0x90;
        const auto disp=static_cast<std::int32_t>(delta);
        std::memcpy(patch.after.data()+1,&disp,sizeof disp);
    }
    FlushInstructionCache(GetCurrentProcess(),stubs,patches.size()*16);
    size_t installed=0;
    for(const auto& patch:patches) {
        if(!write(game<P>(patch.site),patch.after.data(),patch.length)) break;
        ++installed;
    }
    const Command hook=bridge;
    if(installed==patches.size() && write(entry+0x30,&hook,sizeof hook)) return true;
    while(installed) {
        const auto& patch=patches[--installed];
        write(game<P>(patch.site),patch.before.data(),patch.length);
    }
    return false;
}
}

#define LSS_EXPORT extern "C" __declspec(dllexport)
extern "C" {
__declspec(dllexport) OBSEPluginVersionData OBSEPlugin_Version={
    OBSEPluginVersionData::kVersion,2,"Local Split Screen Backend","Local Split Screen contributors",
    0,0,{runtime,0},0,0,0,{}
};
}
LSS_EXPORT bool OBSEPlugin_Load(const OBSEInterface* obse) {
    if(!obse || obse->runtimeVersion!=runtime || !obse->QueryInterface || !obse->GetPluginHandle) return false;
    image=reinterpret_cast<Addr>(GetModuleHandleW(nullptr));
    ready=image && install(obse);
    return ready;
}
LSS_EXPORT U LSS_BackendVersion() { return ready ? 2 : 0; }
LSS_EXPORT U LSS_BackendFeatures() {
    return ready ? feature_compass|feature_topic_catalog|feature_saved_area|feature_guest_torch : 0;
}
LSS_EXPORT bool LSS_ControlGuestTorch(U ref) {
    if(!ready || (ref && (ref>>24)!=0xFF)) return false;
    controlled_torch_actor.store(ref,std::memory_order_relaxed);
    return true;
}
LSS_EXPORT size_t LSS_CopyActorPositionJSON(U key,char* out,size_t cap) { return copy(positions,key,out,cap); }
LSS_EXPORT size_t LSS_CopyDoorJSON(U key,char* out,size_t cap) { return copy(doors,key,out,cap); }
LSS_EXPORT size_t LSS_CopyDialogueJSON(U key,char* out,size_t cap) { return copy(dialogues,key,out,cap); }
LSS_EXPORT size_t LSS_CopyInventoryJSON(U key,char* out,size_t cap) { return copy(inventories,key,out,cap); }
LSS_EXPORT size_t LSS_CopyCompassJSON(U key,char* out,size_t cap) { return copy(compasses,key,out,cap); }
LSS_EXPORT bool LSS_SetTransformHold(Addr component,bool enabled) {
    if(!ready || !component) return false;
    std::lock_guard lock(transform_mutex);
    if(!enabled) { if(held==component) held=0; return true; }
    if(held && GetTickCount64()<deadline) return false;
    held=component; deadline=GetTickCount64()+2400; check_landing=false;
    return true;
}
LSS_EXPORT bool LSS_CheckTransformLanding(Addr component,double x,double y,double z) {
    if(!component || !std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z)) return false;
    std::lock_guard lock(transform_mutex);
    if(held!=component || GetTickCount64()>=deadline) return false;
    landing={x,y,z}; check_landing=true;
    return true;
}
LSS_EXPORT void LSS_TransformLandingCounts(U* good,U* bad) {
    std::lock_guard lock(transform_mutex);
    *good=accepted; *bad=rejected;
}
LSS_EXPORT U LSS_SuppressedTransformCount() {
    std::lock_guard lock(transform_mutex);
    return suppressed;
}
