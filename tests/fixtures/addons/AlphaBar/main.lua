-- undeclared: BaseLib is not in Dependencies, yet this runs at load time
BaseRegister("alphabar")

function AlphaBar_OnLoad()
    return 1
end
