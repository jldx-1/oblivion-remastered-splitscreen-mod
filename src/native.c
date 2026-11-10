/* Win32 input, durable file replacement, and small UE4SS adapters. */
#include <windows.h>
#include <lua.h>
#include <lauxlib.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <wchar.h>
#include <SDL3/SDL.h>

static SDL_Gamepad *pads[4] = {0};
static SDL_JoystickID pad_ids[4] = {0};
static int sdl_initialized = 0;
static int initialize_sdl(void) {
    if (sdl_initialized) return 1;
    HMODULE self = NULL;
    wchar_t path[32768];
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        (LPCWSTR)&initialize_sdl, &self)) return 0;
    if (!GetModuleFileNameW(self, path, 32768)) return 0;
    wchar_t *last = wcsrchr(path, L'\\');
    if (!last) return 0;
    wcscpy_s(last + 1, (size_t)(32768 - (last + 1 - path)), L"SDL3.dll");
    if (!LoadLibraryExW(path, NULL, LOAD_WITH_ALTERED_SEARCH_PATH)) return 0;
    SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI_PS5, "1");
    if (!SDL_InitSubSystem(SDL_INIT_GAMEPAD)) return 0;
    SDL_SetGamepadEventsEnabled(false);
    sdl_initialized = 1;
    return 1;
}

static void integer_field(lua_State *L, const char *name, lua_Integer value) {
    lua_pushinteger(L, value); lua_setfield(L, -2, name);
}
static void bool_field(lua_State *L, const char *name, int value) {
    lua_pushboolean(L, value); lua_setfield(L, -2, name);
}
static int poll(lua_State *L) {
    if (!initialize_sdl()) { lua_pushnil(L); lua_pushstring(L, "SDL controller initialization failed"); return 2; }
    SDL_PumpEvents();
    SDL_UpdateGamepads();
    for (int i = 0; i < 4; ++i) {
        if (pads[i] && !SDL_GamepadConnected(pads[i])) { SDL_CloseGamepad(pads[i]); pads[i] = NULL; pad_ids[i] = 0; }
    }
    int count = 0;
    SDL_JoystickID *ids = SDL_GetGamepads(&count);
    for (int n = 0; ids && n < count; ++n) {
        int known = 0;
        for (int i = 0; i < 4; ++i) if (pad_ids[i] == ids[n]) known = 1;
        if (!known) for (int i = 0; i < 4; ++i) if (!pads[i]) { pads[i] = SDL_OpenGamepad(ids[n]); if (pads[i]) pad_ids[i] = ids[n]; break; }
    }
    SDL_free(ids);
    lua_createtable(L, 4, 0);
    for (DWORD index = 0; index < 4; ++index) {
        lua_createtable(L, 0, 11);
        integer_field(L, "slot", index);
        SDL_Gamepad *pad = pads[index];
        bool_field(L, "connected", pad != NULL);
        if (pad) {
            static const SDL_GamepadButton keys[] = { SDL_GAMEPAD_BUTTON_DPAD_UP, SDL_GAMEPAD_BUTTON_DPAD_DOWN,
                SDL_GAMEPAD_BUTTON_DPAD_LEFT, SDL_GAMEPAD_BUTTON_DPAD_RIGHT, SDL_GAMEPAD_BUTTON_START,
                SDL_GAMEPAD_BUTTON_BACK, SDL_GAMEPAD_BUTTON_LEFT_STICK, SDL_GAMEPAD_BUTTON_RIGHT_STICK,
                SDL_GAMEPAD_BUTTON_LEFT_SHOULDER, SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER,
                SDL_GAMEPAD_BUTTON_SOUTH, SDL_GAMEPAD_BUTTON_EAST, SDL_GAMEPAD_BUTTON_WEST, SDL_GAMEPAD_BUTTON_NORTH };
            static const unsigned masks[] = {1,2,4,8,16,32,64,128,256,512,4096,8192,16384,32768};
            unsigned buttons = 0;
            for (int k=0; k<14; ++k) if (SDL_GetGamepadButton(pad, keys[k])) buttons |= masks[k];
            integer_field(L, "buttons", buttons);
            integer_field(L, "lx", SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFTX));
            integer_field(L, "ly", -(int)SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFTY));
            integer_field(L, "rx", SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_RIGHTX));
            integer_field(L, "ry", -(int)SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_RIGHTY));
            integer_field(L, "lt", SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFT_TRIGGER) / 128);
            integer_field(L, "rt", SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER) / 128);
            integer_field(L, "instance", pad_ids[index]);
            lua_pushstring(L, SDL_GetGamepadName(pad)); lua_setfield(L, -2, "name");
        }
        lua_rawseti(L, -2, index + 1);
    }
    return 1;
}
static int clock_ms(lua_State *L) { lua_pushinteger(L, (lua_Integer)GetTickCount64()); return 1; }
static int focused(lua_State *L) {
    DWORD process = 0;
    GetWindowThreadProcessId(GetForegroundWindow(), &process);
    lua_pushboolean(L, process == GetCurrentProcessId()); return 1;
}
static int key_down(lua_State *L) {
    int key = (int)luaL_checkinteger(L, 1);
    lua_pushboolean(L, (GetAsyncKeyState(key) & 0x8000) != 0); return 1;
}
static wchar_t *wide_path(const char *value) {
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, NULL, 0);
    if (!count || count > 30000) return NULL;
    wchar_t *out = (wchar_t *)calloc((size_t)count + 100, sizeof(wchar_t));
    if (out) MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, out, count);
    return out;
}
static int error_result(lua_State *L, DWORD error) {
    lua_pushnil(L); lua_pushinteger(L, error); return 2;
}
static int profile_directory(lua_State *L) {
    wchar_t directory[MAX_PATH];
    const wchar_t name[]=L"\\OblivionRemasteredLocalSplitScreen";
    DWORD length=GetEnvironmentVariableW(L"LOCALAPPDATA",directory,MAX_PATH);
    if(!length || length+ARRAYSIZE(name)>MAX_PATH) return error_result(L,ERROR_INVALID_NAME);
    memcpy(directory+length,name,sizeof(name));
    if(!CreateDirectoryW(directory,NULL) && GetLastError()!=ERROR_ALREADY_EXISTS)
        return error_result(L,GetLastError());
    char utf8[MAX_PATH*4];
    if(!WideCharToMultiByte(CP_UTF8,0,directory,-1,utf8,sizeof(utf8),NULL,NULL))
        return error_result(L,GetLastError());
    lua_pushstring(L,utf8);
    return 1;
}
static int atomic_write(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    size_t length = 0;
    const char *data = luaL_checklstring(L, 2, &length);
    if (length > 4 * 1024 * 1024) return error_result(L, ERROR_FILE_TOO_LARGE);
    wchar_t *destination = wide_path(path);
    if (!destination) return error_result(L, ERROR_INVALID_NAME);
    size_t capacity = wcslen(destination) + 100;
    wchar_t *temporary = (wchar_t *)calloc(capacity, sizeof(wchar_t));
    wchar_t *backup = (wchar_t *)calloc(capacity, sizeof(wchar_t));
    if (!temporary || !backup) { free(destination); free(temporary); free(backup); return error_result(L, ERROR_OUTOFMEMORY); }
    _snwprintf_s(temporary, capacity, _TRUNCATE, L"%s.%lu.%llu.tmp", destination, GetCurrentProcessId(), GetTickCount64());
    _snwprintf_s(backup, capacity, _TRUNCATE, L"%s.bak", destination);
    HANDLE file = CreateFileW(temporary, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    DWORD error = ERROR_SUCCESS;
    if (file == INVALID_HANDLE_VALUE) error = GetLastError();
    else {
        DWORD written = 0;
        if (!WriteFile(file, data, (DWORD)length, &written, NULL) || written != length || !FlushFileBuffers(file)) error = GetLastError();
        if (written != length && !error) error = ERROR_WRITE_FAULT;
        CloseHandle(file);
        if (!error && GetFileAttributesW(destination) != INVALID_FILE_ATTRIBUTES && !CopyFileW(destination, backup, FALSE)) error = GetLastError();
        if (!error && !MoveFileExW(temporary, destination, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) error = GetLastError();
        if (error) DeleteFileW(temporary);
    }
    free(destination); free(temporary); free(backup);
    if (error) return error_result(L, error);
    lua_pushboolean(L, 1); return 1;
}
typedef unsigned int (*backend_version_fn)(void);
static unsigned int module_protocol(HMODULE module) {
    backend_version_fn version=module ? (backend_version_fn)GetProcAddress(module,"LSS_BackendVersion") : NULL;
    return version ? version() : 0;
}
static HMODULE backend_module(void) {
    HMODULE plugin=GetModuleHandleW(L"LocalSplitScreenBackend.dll");
    if(module_protocol(plugin)==2) return plugin;
    HMODULE legacy=GetModuleHandleW(L"obse64_1_512_105.dll");
    return module_protocol(legacy)==1 ? legacy : NULL;
}
static int backend_protocol(lua_State *L) {
    lua_pushinteger(L,module_protocol(backend_module()));
    return 1;
}
static int backend_features(lua_State *L) {
    HMODULE module=backend_module();
    backend_version_fn features=module ? (backend_version_fn)GetProcAddress(module,"LSS_BackendFeatures") : NULL;
    lua_pushinteger(L,features ? features() : 0);
    return 1;
}
static int backend_snapshot(lua_State *L,const char *export_name,const char *unavailable) {
    typedef size_t (__cdecl *copy_fn)(unsigned int,char*,size_t);
    HMODULE module=backend_module();
    copy_fn copy=module ? (copy_fn)GetProcAddress(module,export_name) : NULL;
    if(!copy) { lua_pushnil(L); lua_pushstring(L,unavailable); return 2; }
    unsigned int ref=(unsigned int)luaL_checkinteger(L,1);
    size_t length=copy(ref,NULL,0);
    if(!length) { lua_pushnil(L); lua_pushstring(L,"Snapshot pending"); return 2; }
    if(length>4*1024*1024) { lua_pushnil(L); lua_pushstring(L,"Snapshot exceeds limit"); return 2; }
    char* buffer=(char*)malloc(length);
    if(!buffer) return error_result(L,ERROR_OUTOFMEMORY);
    size_t actual=copy(ref,buffer,length);
    if(actual!=length) { free(buffer); lua_pushnil(L); lua_pushstring(L,"Snapshot changed; retry"); return 2; }
    lua_pushlstring(L,buffer,length-1); free(buffer); return 1;
}
static int backend_inventory(lua_State *L) {
    return backend_snapshot(L,"LSS_CopyInventoryJSON","Native inventory backend is not loaded");
}
static int backend_door(lua_State *L) {
    return backend_snapshot(L,"LSS_CopyDoorJSON","Native door backend is not loaded");
}
static int backend_actor_position(lua_State *L) {
    return backend_snapshot(L,"LSS_CopyActorPositionJSON","Native actor position backend is not loaded");
}
static int backend_dialogue(lua_State *L) {
    return backend_snapshot(L,"LSS_CopyDialogueJSON","Native dialogue backend is not loaded");
}
static int backend_compass(lua_State *L) {
    return backend_snapshot(L,"LSS_CopyCompassJSON","Native compass backend is not loaded");
}
static int transform_hold(lua_State *L) {
    typedef bool (*hold_fn)(uintptr_t,bool);
    HMODULE module=backend_module();
    hold_fn hold=module ? (hold_fn)GetProcAddress(module,"LSS_SetTransformHold") : NULL;
    const uintptr_t component=(uintptr_t)luaL_checkinteger(L,1);
    lua_pushboolean(L,hold && hold(component,lua_toboolean(L,2)!=0));
    return 1;
}
static int check_transform_landing(lua_State *L) {
    typedef bool (*check_fn)(uintptr_t,double,double,double);
    HMODULE module=backend_module();
    check_fn check=module ? (check_fn)GetProcAddress(module,"LSS_CheckTransformLanding") : NULL;
    const uintptr_t component=(uintptr_t)luaL_checkinteger(L,1);
    const double x=luaL_checknumber(L,2),y=luaL_checknumber(L,3),z=luaL_checknumber(L,4);
    lua_pushboolean(L,check && check(component,x,y,z));
    return 1;
}
static int transform_landing_counts(lua_State *L) {
    typedef void (*count_fn)(unsigned int*,unsigned int*);
    HMODULE module=backend_module();
    count_fn count=module ? (count_fn)GetProcAddress(module,"LSS_TransformLandingCounts") : NULL;
    if(!count) return 0;
    unsigned int accepted,rejected;
    count(&accepted,&rejected);
    lua_pushinteger(L,accepted);
    lua_pushinteger(L,rejected);
    return 2;
}
static int control_guest_torch(lua_State *L) {
    typedef bool (*control_fn)(unsigned int);
    HMODULE module=backend_module();
    control_fn control=module ? (control_fn)GetProcAddress(module,"LSS_ControlGuestTorch") : NULL;
    const unsigned int ref=(unsigned int)luaL_checkinteger(L,1);
    lua_pushboolean(L,control && control(ref));
    return 1;
}
static int null_pairing_count(lua_State *L) {
    typedef bool (*count_fn)(unsigned int*);
    HMODULE module=backend_module();
    count_fn count=module ? (count_fn)GetProcAddress(module,"LSS_NullPairingCount") : NULL;
    unsigned int skipped;
    if(!count || !count(&skipped)) return 0;
    lua_pushinteger(L,skipped);
    return 1;
}
static int suppressed_transforms(lua_State *L) {
    typedef unsigned int (*count_fn)(void);
    HMODULE module=backend_module();
    count_fn count=module ? (count_fn)GetProcAddress(module,"LSS_SuppressedTransformCount") : NULL;
    if(!count) return 0;
    lua_pushinteger(L,count());
    return 1;
}
typedef void *(*get_weak_fn)(const void *);
static int has_activation_target_field(void) {
    // Player_ActivateObject in 1.512.105 resolves a weak UObject at pawn+0x1240.
    // Verify the code that reads this field before examining an engine object.
    static const unsigned char activation_signature[] = {
        0x48,0x8b,0xf9,0x33,0xed,0x48,0x81,0xc1,0x40,0x12,0,0,
        0x44,0x8b,0xf5,0xe8,0x76,0,0x93,0xfe,0x48,0x8b,0xf0
    };
    const size_t activation_rva = 0x4838af6;
    const unsigned char *image = (const unsigned char *)GetModuleHandleW(NULL);
    if (!image) return 0;
    const IMAGE_DOS_HEADER *dos = (const IMAGE_DOS_HEADER *)image;
    const IMAGE_NT_HEADERS *nt = (const IMAGE_NT_HEADERS *)(image + dos->e_lfanew);
    return nt->OptionalHeader.SizeOfImage >= activation_rva + sizeof(activation_signature) &&
        memcmp(image + activation_rva, activation_signature, sizeof(activation_signature)) == 0;
}
static get_weak_fn weak_get(void) {
    HMODULE ue4ss = GetModuleHandleW(L"UE4SS.dll");
    return ue4ss ? (get_weak_fn)GetProcAddress(ue4ss,
        "?Get@FWeakObjectPtr@Unreal@RC@@QEBAPEAVUObject@23@XZ") : NULL;
}
static int activation_target_address(lua_State *L) {
    if (!has_activation_target_field()) return 0;
    get_weak_fn get = weak_get();
    if (!get) return 0;
    uintptr_t pawn = (uintptr_t)luaL_checkinteger(L, 1);
    lua_pushinteger(L, pawn ? (lua_Integer)(uintptr_t)get((const void *)(pawn + 0x1240)) : 0);
    return 1;
}
static int set_weak_component(lua_State *L) {
    typedef void (*assign_weak_fn)(void *, const void *);
    HMODULE ue4ss = GetModuleHandleW(L"UE4SS.dll");
    assign_weak_fn assign = ue4ss ? (assign_weak_fn)GetProcAddress(
        ue4ss, "??4FWeakObjectPtr@Unreal@RC@@QEAAXPEBVUObject@12@@Z") : NULL;
    if (!assign) return luaL_error(L, "UE4SS weak-object assignment is unavailable");
    uintptr_t slot = (uintptr_t)luaL_checkinteger(L, 1);
    uintptr_t component = (uintptr_t)luaL_optinteger(L, 2, 0);
    if (!slot || slot % sizeof(int32_t) != 0)
        return luaL_error(L, "Invalid reflected weak-object slot");
    assign((void *)slot, (const void *)component);
    return 0;
}
__declspec(dllexport) int luaopen_lss_native(lua_State *L) {
    static const luaL_Reg functions[] = {
        {"poll", poll}, {"clock_ms", clock_ms}, {"focused", focused},
        {"key_down", key_down}, {"atomic_write", atomic_write}, {"profile_directory",profile_directory},
        {"backend_protocol",backend_protocol}, {"backend_inventory",backend_inventory},
        {"backend_features",backend_features},
        {"backend_door",backend_door}, {"backend_actor_position",backend_actor_position}, {"backend_dialogue",backend_dialogue},
        {"backend_compass",backend_compass},
        {"activation_target_address",activation_target_address},
        {"transform_hold",transform_hold}, {"suppressed_transforms",suppressed_transforms},
        {"check_transform_landing",check_transform_landing}, {"transform_landing_counts",transform_landing_counts},
        {"control_guest_torch",control_guest_torch},
        {"null_pairing_count",null_pairing_count},
        {"set_weak_component",set_weak_component}, {NULL, NULL}
    };
    luaL_newlib(L, functions); return 1;
}
