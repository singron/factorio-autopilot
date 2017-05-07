local layout = {}

local example_params = {
	origin = {0, 0},
	nodes = {
		{
			name = "offshore-pump",
			count = 1,
		},
		{
			name = "boiler",
			count = 1,
		},
		{
			name = "steam-engine",
			count = 1,
		},
	},
	edges = {
		{
			type = "pipe",
			from = "offshore-pump",
			to = "boiler",
		},
		{
			type = "pipe",
			from = "boiler",
			to = "steam-engine",
		}
	},
}

local solution = {
	entities = {
		{
			name = "offshore-pump",
			position = {1, 2},
			direction = defines.direction.north,
		},
		{
			name = "boiler",
			position = {1, 3},
			direction = defines.direction.north,
		},
		{
			name = "steam-engine",
			position = {1, 4},
			direction = defines.direction.north,
		},
	},
}

-- return a solution
-- params has
function layout:layout(player, params) -- luacheck: ignore self
	local origin = params.origin or player.position --luacheck: ignore origin
end

local example_chunk = {
	area = {{3, 4},
	        {-1, -2}},
	outputs = {
		name = "water",
		type = "pipe",
		position = {3, 4},
		direction = defines.direction.north,
	},
	inputs = {},
	fluid = "water",
	entities = {
		{
			name = "offshore-pump",
			position = {3,4},
			direction = defines.direction.north,
		},
	},
}

local function make_chunk(node)
	local proto = game.entity_prototypes[node.name]
	local chunk = {}
	if node.count == 1 then
		chunk.entities = {
			name = node.name,
			position = {0, 0},
		}
		if proto.fluid ~= nil then
			chunk.fluid = proto.fluid
		end
		if proto.pipe_connections then
			game.print('connect pipes')
		end
	else
		game.print('cannot layout multi node counts')
		node.fix.this()
	end
	return chunk
end

function layout.test()
	example_params = example_params
	example_chunk = example_chunk
	solution = solution
	make_chunk(nil)
end

return layout
