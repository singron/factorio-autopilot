local util = require('util')
local player;
local made_by = {}

local Status = {
	DONE = {},
	BUSY = {},
	WAIT = {},
	ERR = {},
}

local _Status = {}

function _Status:is_done()
	return self.kind == Status.DONE
end
function _Status:is_busy()
	return self.kind == Status.BUSY
end
function _Status:is_wait()
	return self.kind == Status.WAIT
end
function _Status:is_err()
	return self.kind == Status.ERR
end

function _Status:tostring()
	return self.desc
end

local DEBUG_STATUS = false

local function new_status(kind)
	local ks = 'UNKNOWN'
	if kind == Status.DONE then
		ks = 'DONE'
	elseif kind == Status.BUSY then
		ks = 'BUSY'
	elseif kind == Status.WAIT then
		ks = 'WAIT'
	elseif kind == Status.ERR then
		ks = 'ERR'
	end

	local s = {
		kind = kind,
	}
	if DEBUG_STATUS then
		local i = debug.getinfo(2, 'nSl')
		s.desc = ks..'('..(i.name or '_')..':'..i.short_src..':'..i.currentline..')'
	else
		s.desc = ks
	end
	setmetatable(s, {__index = _Status})
	return s
end

function Status.done()
	return new_status(Status.DONE)
end

function Status.busy()
	return new_status(Status.BUSY)
end

function Status.wait()
	return new_status(Status.WAIT)
end

function Status.err()
	return new_status(Status.ERR)
end

local function is_status(x)
	if x == nil then
		return false
	end
	local m = getmetatable(x)
	if m == nil then
		return false
	end
	return m.__index == _Status
end

local function status_tostring(x)
	return x:tostring()
end

local function player_inventories()
	local res = {}
	for name, inv in pairs(defines.inventory) do
		if name == 'player_main' or name == 'player_quickbar' then
			local i = player.get_inventory(inv)
			if i ~= nil then
				table.insert(res, i)
			end
		end
	end
	return res
end

local function player_inv_get_item_count(name)
	local count = 0
	for _, inv in ipairs(player_inventories()) do
		count = count + inv.get_item_count(name)
	end
	return count
end

local function player_inv_remove(stack)
	stack.count = stack.count or 1
	local count = 0
	for _, inv in ipairs(player_inventories()) do
		local c = inv.remove({name = stack.name, count = stack.count - count})
		count = count + c
		if count >= stack.count then
			return count
		end
	end
	player.print('Only removed '..count..'/'..stack.count..' of '..stack.name)
	return count
end

local function player_inv_can_insert(stack)
	return player.get_inventory(defines.inventory.player_main).insert(stack)
end

local function player_inv_insert(stack)
	return player.get_inventory(defines.inventory.player_main).insert(stack)
end

local Reservation = {}

-- Inventory is reserved so that one (high priority) plan doesn't keep
-- gathering an item that gets consumed in another plan.
local inventory_reservations = {}

function Reservation:new()
	local r = {
		items = {},
	}
	setmetatable(r, {__index = self})
	return r
end

function Reservation:take(res)
	if res == nil or res.items == nil then
		return
	end
	for item, count in pairs(res.items) do
		self.items[item] = (self.items[item] or 0) + count
	end
	res.items = {}
end

-- Returns the amount actually allocated.
function Reservation:alloc_item(item, count)
	local reserved = inventory_reservations[item] or 0
	local have = player_inv_get_item_count(item)
	local avail = have - reserved
	if avail < count then
		count = avail
	end
	self.items[item] = (self.items[item] or 0) + count
	inventory_reservations[item] = reserved + count
	return count
end

function Reservation:alloc_item_to(item, want_count)
	local count = self:item_count(item)
	if count < want_count then
		local added = self:alloc_item(item, want_count - count)
		count = count + added
	end
	return count
end

function Reservation:use_item(item, count)
	count = self:free_item(item, count)
	local have = player_inv_get_item_count(item)
	if count > have then
		count = have
	end
	count = player_inv_remove({name=item, count=count})
	return count
end

function Reservation:create_item(item, count)
	count = player_inv_insert({name=item, count=count})
	return self:alloc_item(item, count)
end

function Reservation:free_item(item, count)
	if (self.items[item] or 0) < count then
		player.print('ERROR tried to free '..tostring(count)..' but have '..tostring(self.items[item]))
		count = self.items[item] or 0
	end
	local reserved = inventory_reservations[item] or 0
	if reserved < count then
		player.print('ERROR tried to free '..tostring(count)..' but have '..tostring(reserved)..' globally')
		count = reserved
	end
	self.items[item] = (self.items[item] or 0) - count
	inventory_reservations[item] = reserved - count
	return count
end

function Reservation:free()
	local items = {}
	-- Can't iterate while mutating, so make a copy.
	for item, _ in pairs(self.items) do
		table.insert(items, item)
	end
	for _, item in ipairs(items) do
		self:free_item(item, self.items[item])
	end
end

function Reservation:item_count(item)
	local count = self.items[item] or 0
	local actual_count = player_inv_get_item_count(item)
	if count > actual_count then
		player.print('ERROR bad count')
		count = actual_count
	end
	return count
end

function Reservation:total_items()
	local total = 0
	for _, count in pairs(self.items) do
		total = total + count
	end
	return total
end

function Reservation:tostring()
	local s = 'Res('
	local comma = false
	for item, count in pairs(self.items) do
		if comma then
			s = s..','
		end
		s = s .. item..'='..tostring(count)
		comma = true
	end
	s = s .. ')'
	return s
end

local Plan = {}
Plan.__index = Plan

function Plan:new_plan_type()
	local base = self
	local plan = {super=base}
	function plan.raw_new()
		local inst = {}
		setmetatable(inst, { __index = plan })
		inst.started = false
		inst.updated = false
		inst.name = "unknown plan"
		inst.deps = {}
		inst.reservation = Reservation:new()
		return inst
	end
	setmetatable(plan, { __index = base })
	return plan
end

function Plan:is_plan(plan)
	local m = getmetatable(self)
	return m.__index == plan
end

function Plan:print(prefix)
	local status = self:check_status()
	print(prefix..self.name..' '..status_tostring(status)..' '..self.reservation:tostring())
	for _, dep in ipairs(self.deps) do
		dep:print(prefix..'-')
	end
end

function Plan:take_deps(res)
	for _, dep in ipairs(self.deps) do
		dep:take_deps(res)
		res:take(dep.reservation)
	end
end

function Plan:clear_deps()
	if #self.deps > 0 then
		for _, dep in ipairs(self.deps) do
			dep:do_free()
		end
		self.deps = {}
	end
end

function Plan:free()
	self.reservation:free()
end

function Plan:do_free()
	self:clear_deps()
	self:free()
end

function Plan:do_check_status()
	local busy = false
	local wait = false
	local err = false
	for _, dep in ipairs(self.deps) do
		local dep_status = dep:do_check_status()
		if dep_status:is_busy() then
			busy = true
		elseif dep_status:is_wait() then
			wait = true
		elseif dep_status:is_err() then
			err = true
		end
	end
	if busy then
		return (Status.busy())
	elseif wait then
		return (Status.wait())
	elseif err then
		return (Status.err())
	end
	return (self:check_status())
end

function Plan:check_status() -- luacheck: ignore self
	return (Status.done())
end

function Plan:do_update(prefix)
	if not self.started then
		player.print(prefix.."Starting "..self.name)
		self.started = true
	end
	local status = self:do_check_status()
	if status:is_done() then
		if self.started then
			player.print(prefix..'Finished '..self.name)
		end
		self.updated = false
		self.started = false
		return status
	end
	local wait = false
	local err = false
	for _, dep in ipairs(self.deps) do
		local dep_status = dep:do_check_status()
		if dep_status:is_busy() then
			local new_dep_status = dep:do_update(prefix..'-')
			self.updated = false
			if not is_status(new_dep_status) or new_dep_status:is_busy()then
				return (Status.busy())
			end
			dep_status = new_dep_status
		end
		if dep_status:is_done() then
			if dep.started then
				player.print(prefix..'Finished '..dep.name)
			end
			dep.started = false
			dep.updated = false
		elseif dep_status:is_wait() then
			wait = true
		elseif dep_status:is_err() then
			err = true
		end
	end
	if wait then
		return (Status.wait())
	elseif err then
		return (Status.err())
	end
	-- All deps are done.
	if not self.updated then
		player.print(prefix.."Updating "..self.name)
	end
	status = self:update()
	self.updated = true
	if not is_status(status) then
		player.print('ERROR: bad status from '..self.name..': '..status_tostring(status))
		-- say busy so that it gets checked next tick
		return (Status.busy())
	end
	return status
end

function Plan:update() -- luacheck: ignore self
end

local MoveNear = Plan:new_plan_type()

local ChopTree = Plan:new_plan_type()


function MoveNear:new(dest, dist)
	local move = self.raw_new()
	move.dest = dest
	move.dist = dist - 0.1
	move.name = "MoveNear(("..tostring(dest.x)..","..tostring(dest.y).."),"..tostring(dist)..")"
	move.past_positions = {}
	move.wander_count = 0
	move.stuck_count = 0
	return move
end

function MoveNear:check_status()
	local dir = self:direction()
	if dir.hor == 0 and dir.vert == 0 then
		return (Status.done())
	end
	return (Status.busy())
end

function MoveNear:direction()
	local pos = player.position
	local dx = self.dest.x - pos.x
	local dy = self.dest.y - pos.y
	local vert = 0;
	local hor = 0;
	if dy > self.dist then
		vert = 1
	elseif dy < -self.dist then
		vert = -1
	end
	if dx > self.dist then
		hor = 1
	elseif dx < -self.dist then
		hor = -1
	end
	return {hor=hor, vert=vert}
end

local function filter(t, f)
	if t == nil then
		return t
	end
	local res = {}
	for _, v in ipairs(t) do
		if f(v) then
			table.insert(res, v)
		end
	end
	return res
end

local function minimum(list, key)
	local min = nil
	local min_val = nil
	for _, l in ipairs(list) do
		local l_val = key(l)
		if min == nil or l_val < min_val  then
			min = l
			min_val = l_val
		end
	end
	return min
end

local function entity_distance_to_player(e)
	return util.distance(e.position, player.position)
end

local function get_nearest_tree()
	local size = 100
	local trees = player.surface.find_entities_filtered({
		area = {{player.position.x - size, player.position.y - size},
		        {player.position.x + size, player.position.y + size}},
		type = "tree",
	})
	trees = filter(trees, function(t)
		return t.valid and t.health > 0
	end)
	local tree = minimum(trees, entity_distance_to_player)
	if tree == "nil" then
		player.print("Could not find tree")
		return nil
	end
	return tree
end

local function pick_random(t)
	local keys = {}
	local i = 1
	for k, _ in pairs(t) do
		keys[i] = k
		i = i + 1
	end
	return t[keys[math.random(1, #keys)]]
end

function MoveNear:update()
	self:clear_deps()
	if self.wander_count > 0 then
		player.walking_state = {
			walking = true,
			direction = self.wander,
		}
		self.wander_count = self.wander_count - 1
		return (Status.busy())
	end
	if #self.past_positions >= 10 then
		local dist = util.distance(self.past_positions[1], player.position)
		self.past_positions = {}
		if dist < 0.1 then
			local tree = get_nearest_tree()
			if tree ~= nil and entity_distance_to_player(tree) < 1 then
				table.insert(self.deps, ChopTree:new(tree))
				return (Status.busy())
			end
			player.print('stuck')
			self.wander = pick_random(defines.direction)
			self.wander_count = math.random(10, 10 + self.stuck_count)
			self.stuck_count = self.stuck_count + 1
			return (Status.busy())
		end
	end
	table.insert(self.past_positions, player.position)
	local godir = self:direction()
	local hor = godir.hor
	local vert = godir.vert
	local dir = nil;
	if hor == 0 and vert == 0 then
		player.walking_state = {
			walking = false,
			direction = defines.direction.north,
		}
		return (Status.done())
	end
	if hor == 0 then
		if vert > 0 then
			dir = defines.direction.south
		elseif vert < 0 then
			dir = defines.direction.north
		end
	elseif hor > 0 then
		if vert > 0 then
			dir = defines.direction.southeast
		elseif vert < 0 then
			dir = defines.direction.northeast
		else
			dir = defines.direction.east
		end
	elseif hor < 0 then
		if vert > 0 then
			dir = defines.direction.southwest
		elseif vert < 0 then
			dir = defines.direction.northwest
		else
			dir = defines.direction.west
		end
	end
	player.walking_state = {
		direction = dir,
		walking = true,
	}
	return (Status.busy())
end

local function get_nearest_ore(name)
	local size = 4096
	local res = player.surface.find_entities_filtered({
		area = {{player.position.x - size, player.position.y - size},
		        {player.position.x + size, player.position.y + size}},
		name = name,
	})
	local ore = minimum(res, entity_distance_to_player)
	if ore == nil then
		player.print('Could not find nearest '..name)
	end
	return ore
end

local MineOre = Plan:new_plan_type()

function MineOre:new(tile, amount)
	local plan = self.raw_new()
	plan.tile = tile
	plan.amount = amount
	plan.name = "MineOre("..tile.name..","..amount..")"
	plan.last_amount = tile.amount
	plan.deps = {
		MoveNear:new(tile.position, 2),
	}
	return plan
end

function MineOre:check_status()
	if not self.tile.valid or self.reservation:item_count(self.tile.name) >= self.amount then
		return (Status.done())
	end
	return (Status.busy())
end

function MineOre:update()
	if player.selected ~= self.tile then
		player.update_selected_entity(self.tile.position)
		if player.selected ~= self.tile then
			player.walking_state = {
				walking = true,
				direction = pick_random(defines.direction),
			}
		end
	end
	if player.mining_state.mining ~= true or player.mining_state.position ~= self.tile.position then
		player.mining_state = {
			mining = true,
			position = self.tile.position,
		}
	end
	self.reservation:alloc_item(self.tile.name, self.last_amount - self.tile.amount)
	return (Status.busy())
end

function ChopTree:new(tree)
	local plan = self.raw_new()
	plan.tree = tree
	plan.name = "Chop tree"
	plan.deps = {
		MoveNear:new(tree.position, 1),
	}
	return plan
end

function ChopTree:check_status()
	if self.tree.valid then
		return (Status.busy())
	end
	return (Status.done())
end

function ChopTree:update()
	if player.selected ~= self.tree then
		player.update_selected_entity(self.tree.position)
		if player.selected ~= self.tile then
			player.walking_state = {
				walking = true,
				direction = pick_random(defines.direction),
			}
		end
	end
	if player.mining_state.mining ~= true or player.mining_state.position ~= self.tree.position then
		player.mining_state = {
			mining = true,
			position = self.tree.position,
		}
	end
	return (Status.busy())
end

local SmeltItem = Plan:new_plan_type()

function SmeltItem:new(item, amount, recipe)
	local plan = self.raw_new()
	plan.item = item
	plan.amount = amount
	plan.recipe = recipe
	plan:set_name()

	plan.recipe_amount = 0
	for _, p in ipairs(recipe.products) do
		if p.name == plan.item then
			plan.recipe_amount = plan.recipe_amount + p.amount
		end
	end
	if plan.recipe_amount <= 0 then
		player.print('weirdly cannot make '..item..' with '..recipe.name)
	end
	return plan
end

function SmeltItem:smelter_input()
	local out = {}
	local in_inv = self.smelter.get_inventory(defines.inventory.furnace_source)
	for _, ing in ipairs(self.recipe.ingredients) do
		 out[ing.name] = in_inv.get_item_count(ing.name)
	end
	return out
end

function SmeltItem:pending_amount()
	if self.smelter == nil then
		return 0
	end

	local fuel_inv = self.smelter.get_fuel_inventory()
	if fuel_inv.is_empty() then
		return 0
	end

	local pending_in = self:smelter_input()
	local runs = 100
	for _, ing in ipairs(self.recipe.ingredients) do
		local ing_runs = math.ceil(pending_in[ing.name] / ing.amount)
		if ing_runs < runs then
			runs = ing_runs
		end
	end

	if self.smelter.is_crafting() then
		runs = runs + 1
	end

	return self.recipe_amount * runs
end

local entity_cache = {}

local GetItem = Plan:new_plan_type()

function SmeltItem:set_name()
	self.name = 'SmeltItem('..self.item..','..tostring(self.amount)..','..tostring(self.smelter)..')'
end

function SmeltItem:set_smelter()
	if self.smelter ~= nil then
		if self.smelter.valid then
			return true
		end
		self.smelter = nil
	end

	-- Check cache
	for i, e in ipairs(entity_cache) do
		if e.name == 'stone-furnace' and not e.is_crafting() then
			self.smelter = e
			table.remove(entity_cache, i)
			self:set_name()
			return true
		end
	end

	-- Check inventory
	local furnace = 'stone-furnace'
	if self.reservation:alloc_item_to(furnace, 1) < 1 then
		table.insert(self.deps, GetItem:new(furnace, 1))
		return false
	end
	local surf = player.surface
	local pos = surf.find_non_colliding_position(furnace, player.position, 100, 4)
	if pos == nil then
		player.print('cannot find position for stone-furnace')
		return false
	end
	self.smelter = surf.create_entity({
		name = furnace,
		position = pos,
		force = player.force,
	})
	if self.smelter == nil then
		player.print('could not create furnace')
		return false
	end
	self:set_name()

	if self.reservation:use_item(furnace, 1) < 1 then
		player.print('Did not remove item from inventory')
	end
	return true
end

function SmeltItem:free()
	if self.smelter ~= nil then
		table.insert(entity_cache, self.smelter)
		self.smelter = nil
	end
end

function SmeltItem:go_near_smelter()
	table.insert(self.deps, MoveNear:new(self.smelter.position, 2))
end

function SmeltItem:is_smelter_full()
	local out_inv = self.smelter.get_output_inventory()
	for _, ing in ipairs(self.recipe.products) do
		if not out_inv.can_insert({name = ing.name, count = ing.amount}) then
			return true
		end
	end
	return false
end

function SmeltItem:empty_smelter()
	local out_inv = self.smelter.get_output_inventory()
	for item, count in pairs(out_inv.get_contents()) do
		local stack = {name=item, count=count}
		if player_inv_can_insert(stack) then
			out_inv.remove(stack)
			player_inv_insert(stack)
			if item == self.item then
				self.reservation:alloc_item(item, count)
			end
		else
			player.print('cannot empty furnace')
			return false
		end
	end
	return true
end

function SmeltItem:need_fuel()
	local fuel_inv = self.smelter.get_fuel_inventory()
	return fuel_inv.is_empty()
end

function SmeltItem:need_empty()
	local out_inv = self.smelter.get_output_inventory()
	local reserved = self.reservation:item_count(self.item)
	local out = out_inv.get_item_count(self.item)
	return self:is_smelter_full() or out + reserved >= self.amount
end

-- Return table of item to remaining count needed.
function SmeltItem:feeding_amounts()
	local out_inv = self.smelter.get_output_inventory()
	local pending = out_inv.get_item_count(self.item)
	local remaining = self.amount - self.reservation:item_count(self.item) - pending
	local remaining_runs = math.ceil(remaining / self.recipe_amount)
	if self.smelter.is_crafting() then
		remaining_runs = remaining_runs - 1
	end

	local amounts = {}
	local in_inv = self.smelter.get_inventory(defines.inventory.furnace_source)
	for _, ing in ipairs(self.recipe.ingredients) do
		local needed = remaining_runs * ing.amount
		local tofeed = needed - in_inv.get_item_count(ing.name)
		if tofeed > 0 then
			amounts[ing.name] = tofeed
		else
			amounts[ing.name] = 0
		end
	end
	return amounts
end

function SmeltItem:need_feed(amounts)
	local in_inv = self.smelter.get_inventory(defines.inventory.furnace_source)
	local any_empty = false
	for _, ing in ipairs(self.recipe.ingredients) do
		local have = in_inv.get_item_count(ing.name)
		if amounts[ing.name] > 0 and have < ing.amount then
			any_empty = true
		end
	end
	return any_empty
end

function SmeltItem:check_status()
	if self.reservation:item_count(self.item) >= self.amount then
		return (Status.done())
	end
	if self.smelter == nil or not self.smelter.valid then
		return (Status.busy())
	end
	if self:need_empty() then
		return (Status.busy())
	end
	if self:need_fuel() then
		return (Status.busy())
	end
	local feed_amounts = self:feeding_amounts()
	if self:need_feed(feed_amounts) then
		return (Status.busy())
	end
	return (Status.wait())
end

function SmeltItem:update()
	self:take_deps(self.reservation)
	self:clear_deps()
	if not self:set_smelter() then
		return (Status.busy())
	end

	local near_smelter = entity_distance_to_player(self.smelter) < 3

	if self:need_empty() then
		if not near_smelter then
			self:go_near_smelter()
			return (Status.busy())
		end
		if not self:empty_smelter() then
			return (Status.err())
		end

		if self.reservation:item_count(self.item) >= self.amount then
			return (Status.done())
		end
	end

	if self:need_fuel() then
		local fuel_inv = self.smelter.get_fuel_inventory()
		local fuel_amount = self.reservation:alloc_item_to('raw-wood', 20)
		if fuel_amount < 1 then
			table.insert(self.deps, GetItem:new('raw-wood', 20))
			return (Status.busy())
		end
		if not near_smelter then
			self:go_near_smelter()
			return (Status.busy())
		end
		if fuel_amount > 20 then
			fuel_amount = 20
		end
		local stack = {name='raw-wood', count=fuel_amount}
		local insert_amount = fuel_inv.insert(stack)
		if insert_amount > 0 then
			self.reservation:use_item('raw-wood', insert_amount)
		else
			player.print('could not fuel furnace')
			return (Status.err())
		end
	end

	local pending_amount = self:pending_amount()
	if self.reservation:item_count(self.item) + pending_amount >= self.amount then
		return (Status.wait())
	end

	local feed_amounts = self:feeding_amounts()
	if not self:need_feed(feed_amounts) then
		return (Status.wait())
	end

	local real_feed_amounts = {}

	local in_inv = self.smelter.get_inventory(defines.inventory.furnace_source)
	for _, ing in ipairs(self.recipe.ingredients) do
		local inv_amount = in_inv.get_item_count(ing.name)
		local stack_size = game.item_prototypes[ing.name].stack_size
		local have = self.reservation:item_count(ing.name)
		local tofeed = feed_amounts[ing.name]
		if tofeed + inv_amount > stack_size then
			tofeed = stack_size - inv_amount
		end
		if have < tofeed then
			table.insert(self.deps, GetItem:new(ing.name, tofeed))
			return (Status.busy())
		end
		real_feed_amounts[ing.name] = tofeed
	end

	if not near_smelter then
		self:go_near_smelter()
		return (Status.busy())
	end
	for _, ing in ipairs(self.recipe.ingredients) do
		local amount = real_feed_amounts[ing.name]
		if in_inv.can_insert({name=ing.name, count=amount}) then
			amount = in_inv.insert({name=ing.name, count=amount})
			if ing.name == nil then
				ing.name.what.what = 1
			end
			self.reservation:use_item(ing.name, amount)
		else
			player.print('cannot insert into furnace')
			return (Status.err())
		end
	end
	return (Status.wait())
end

function GetItem:new(item, amount)
	local plan = self.raw_new()
	plan.item = item
	plan.amount = amount
	plan.name = "GetItem("..item..","..amount..")"
	local recipes = made_by[item]
	if recipes == nil then
		player.print('cannot make '..item)
		return plan
	end
	local recipe = filter(recipes, function(r)
		return r.valid and r.enabled and not r.hidden
	end)[1]
	if recipe == nil then
		player.print('cannot handmake '..item)
		return plan
	end
	plan.recipe_amount = 0
	for _, p in ipairs(recipe.products) do
		if p.name == plan.item then
			plan.recipe_amount = plan.recipe_amount + p.amount
		end
	end
	if plan.recipe_amount > 0 then
		plan.recipe = recipe
	else
		player.print('weirdly cannot make '..item..' with '..recipe.name)
	end
	return plan
end

function GetItem:get_inv_count()
	return self.reservation:item_count(self.item)
end

function GetItem:check_status()
	if self:get_inv_count() >= self.amount then
		return (Status.done())
	end
	return (Status.busy())
end

function GetItem:craft_update()
	local crafting_count = 0
	-- TODO: reserve ingredients
	if player.crafting_queue ~= nil then
		for _, q in ipairs(player.crafting_queue) do
			if q.recipe == self.recipe.name then
				crafting_count = crafting_count + q.count * self.recipe_amount
			end
		end
	end
	local inv_count = self:get_inv_count()
	if inv_count + crafting_count >= self.amount then
		return (Status.wait())
	end
	-- We must craft now
	local togo = self.amount - inv_count - crafting_count
	local runs = math.ceil(togo / self.recipe_amount)
	local runs_now = runs
	for _, ing in ipairs(self.recipe.ingredients) do
		local needed = runs * ing.amount
		local avail = self.reservation:alloc_item_to(ing.name, needed)
		local can_run = math.floor(avail / ing.amount)
		if can_run < runs_now then
			runs_now = can_run
		end
	end
	if runs_now > 0 then
		runs_now = player.begin_crafting({count=runs_now, recipe=self.recipe})
		for _, ing in ipairs(self.recipe.ingredients) do
			self.reservation:free_item(ing.name, ing.amount * runs_now)
		end
	end
	local runs_to_get = runs - runs_now
	if runs_to_get == 0 then
		return (Status.wait())
	end
	-- We need more ingredients
	for _, ing in ipairs(self.recipe.ingredients) do
		local needed = runs_to_get * ing.amount
		local avail = self.reservation:alloc_item_to(ing.name, needed)
		if needed > avail then
			table.insert(self.deps, GetItem:new(ing.name, needed - avail))
		end
	end
	return (Status.busy())
end

function GetItem:update()
	self:take_deps(self.reservation)
	self:clear_deps()
	if self.reservation:alloc_item_to(self.item, self.amount) > self.amount then
		return (Status.done())
	end
	local prototype = game.item_prototypes[self.item]
	if self.reservation:item_count(self.item) < self.amount then
		if prototype.type == "mining-tool" then
			local tool_inv = player.get_inventory(defines.inventory.player_tools)
			local count = tool_inv.get_item_count(self.item)
			if count > 1 then
				count = self.reservation:create_item(self.item, count - 1)
				tool_inv.remove({name = self.item, count = count})
			end
		end
	end
	local status = self:check_status()
	if status == Status.done() then
		return status
	end
	if self.recipe ~= nil then
		if self.recipe.category == nil or self.recipe.category == "crafting" then
			return self:craft_update()
		end
		table.insert(self.deps, SmeltItem:new(self.item, self.amount, self.recipe))
		return (Status.busy())
	end
	if self.item == "raw-wood" then
		table.insert(self.deps, ChopTree:new(get_nearest_tree()))
	elseif (self.item == "iron-ore" or
			self.item == "copper-ore" or
			self.item == "coal" or
		    self.item == "stone") then
		table.insert(self.deps, MineOre:new(get_nearest_ore(self.item), self.amount))
	else
		player.print('no way to get '..self.item)
		return (Status.err())
	end
	return (Status.busy())
end

local EquipItem = Plan:new_plan_type()

function EquipItem:new(item, count)
	local plan = self.raw_new()
	plan.item = item
	plan.count = count
	local prototype = game.item_prototypes[item]
	if prototype.type == "mining-tool" then
		plan.inventory = defines.inventory.player_tools
	else
		plan.inventory = defines.inventory.player_guns
	end
	return plan
end

function EquipItem:check_status()
	if self.reservation:total_items() > 0 then
		return (Status.busy())
	end
	local inv = player.get_inventory(self.inventory)
	if inv.get_item_count(self.item) >= self.count then
		return (Status.done())
	end
	return (Status.busy())
end

function EquipItem:update()
	self:clear_deps()
	self.reservation:free()
	-- We don't care if we had it reserved or not.
	local inv = player.get_inventory(self.inventory)
	local count = inv.get_item_count(self.item)
	if count >= self.count then
		return (Status.done())
	end
	local inv_count = self.reservation:alloc_item_to(self.item, self.count - count)
	if inv_count > 0 then
		inv_count = inv.insert({name=self.item, count=inv_count})
		player_inv_remove({name=self.item, count=inv_count})
	end
	count = inv.get_item_count(self.item)
	if count >= self.count then
		return (Status.done())
	end
	table.insert(self.deps, GetItem:new(self.item, self.count - count))
	return (Status.busy())
end

local MasterPlan = Plan:new_plan_type()

function MasterPlan:new()
	local plan = self.raw_new()
	plan.deps = {
		EquipItem:new("iron-axe", 2),
		GetItem:new("boiler", 14),
		GetItem:new("steam-engine", 10),
		GetItem:new("offshore-pump", 1),
	}
	return plan
end

local action = nil
local deptree_button = nil
local pause_button = nil
local ff_button = nil
local one_x_button = nil

script.on_event(defines.events.on_player_created, function(event)
	if player ~= nil then
		return
	end
	player = game.players[event.player_index]
	player.print("controlling")
	local recipes = player.force.recipes
	made_by = {}
	for _, r in pairs(recipes) do
		for _, p in ipairs(r.products) do
			local rs = made_by[p.name] or {}
			table.insert(rs, r)
			made_by[p.name] = rs
		end
	end
	action = MasterPlan:new()
	-- action = nil
	player_inv_insert({name = "assembling-machine-1", count = 100})
	player_inv_insert({name = "transport-belt", count = 400})
	player_inv_insert({name = "inserter", count = 200})
	player_inv_insert({name = "small-electric-pole", count = 100})
	player_inv_insert({name = "pipe", count = 100})
	player_inv_insert({name = "chemical-plant", count = 10})
	player_inv_insert({name = "oil-refinery", count = 10})
	player_inv_insert({name = "offshore-pump", count = 10})
	player_inv_insert({name = "boiler", count = 10})
	player_inv_insert({name = "coal", count = 100})
	game.speed = 1.0
	deptree_button = player.gui.top.add({type='button', name='deptree'})
	deptree_button.caption = 'Show deptree'
	pause_button = player.gui.top.add({type='button', name='pause'})
	pause_button.caption = 'Pause'
	one_x_button = player.gui.top.add({type='button', name='one_x'})
	one_x_button.caption = '1x'
	ff_button = player.gui.top.add({type='button', name='ff'})
	ff_button.caption = 'ff'
end)

local paused = false
local game_speed = 1.0

script.on_event(defines.events.on_gui_click, function(event)
	if event.element == deptree_button then
		if action ~= nil then
			action:print('+')
		end
	elseif event.element == pause_button then
		if paused then
			pause_button.caption = 'Pause'
			paused = false
		else
			pause_button.caption = 'Resume'
			paused = true
		end
	elseif event.element == ff_button then
		if game_speed < 5.0 then
			game_speed = 5.0
		else
			game_speed = game_speed + 5.0
		end
		player.print('Setting game.speed to '..tostring(game_speed))
		game.speed = game_speed
	elseif event.element == one_x_button then
		game_speed = 1.0
		game.speed = game_speed
		player.print('Setting game.speed to 1.0')
	end
end)

script.on_event(defines.events.on_tick, function(event) -- luacheck: ignore event
	if player == nil or paused or action == nil then
		return
	end

	local status = action:do_update('+')
	if is_status(status) and status:is_done() then
		action:do_free()
		action = nil
		player.print("plan done after "..event.tick..' ticks')
	end
end)
