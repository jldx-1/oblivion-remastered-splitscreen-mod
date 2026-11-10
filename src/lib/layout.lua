local Layout={stacked=0,side_by_side=1}

function Layout.anchors(layout,player,top,bottom)
    local start=(player-1)*0.5
    top,bottom=top or 0,bottom or 1
    if layout==Layout.stacked then
        return {Minimum={X=0,Y=start+top*0.5},Maximum={X=1,Y=start+bottom*0.5}}
    end
    return {Minimum={X=start,Y=top},Maximum={X=start+0.5,Y=bottom}}
end

function Layout.label(layout)
    return layout==Layout.stacked and "Top / Bottom" or "Left / Right"
end

return Layout
