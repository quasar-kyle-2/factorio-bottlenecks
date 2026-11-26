data:extend({
    {
        type = "int-setting",
        name = "bottleneck-calc-extreme-work-per-tick",
        setting_type = "runtime-per-user",
        default_value = 1000000,
        minimum_value = 10000,
        maximum_value = 100000000,
        order = "a",
    },
    {
        type = "bool-setting",
        name = "bottleneck-calc-extreme-use-analyzer",
        setting_type = "runtime-per-user",
        default_value = true,
        order = "b",
    },
    {
        type = "int-setting",
        name = "bottleneck-calc-extreme-max-rows",
        setting_type = "runtime-per-user",
        default_value = 150,
        minimum_value = 10,
        maximum_value = 5000,
        order = "c",
    },
})
