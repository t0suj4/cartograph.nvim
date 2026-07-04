function MiniInit()
    MiniState = {}
end

-- the classic bug: widgets/late.lua loads after this line runs
LateHelper()
