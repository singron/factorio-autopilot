local util = require('util')
local player;
local made_by = {}

local Status = {}
Status.DONE = {}
Status.BUSY = {}
Status.WAIT = {}
Status.ERROR = {}

local function is_status(x)
	if x == nil then
		return false
	end
	for _, s in pairs(Status) do
		if s == x then
			return true
		end
	end
	return false
end

local function status_tostring(x)
	for n, s in pairs(Status) do
		if s == x then
			return n
		end
	end
	return 'UNKNOWN('..tostring(x)..')'
end

local function startswith(s, prefix)
	return string.sub(s, 1,string.len(prefix))==prefix
end

local function player_inventories()
	local res = {}
	for name, inv in pairs(defines.inventory) do
		if startswith(name, 'player_') then
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
		return inst
	end
	setmetatable(plan, { __index = base })
	return plan
end

function Plan:print(prefix)
	print(prefix..self.name..' '..status_tostring(self:check_status()))
	for _, dep in ipairs(self.deps) do
		dep:print(prefix..'-')
	end
end

function Plan:clear_deps()
	if #self.deps > 0 then
		self.deps = {}
	end
end

function Plan:do_check_status()
	local busy = false
	local wait = false
	local err = false
	for _, dep in ipairs(self.deps) do
		local dep_status = dep:do_check_status()
		if dep_status == Status.BUSY then
			busy = true
		elseif dep_status == Status.WAIT then
			wait = true
		elseif dep_status == Status.ERROR then
			err = true
		end
	end
	if busy then
		return Status.BUSY
	elseif wait then
		return Status.WAIT
	elseif err then
		return Status.ERROR
	end
	return self:check_status()
end

function Plan:check_status() -- luacheck: ignore self
	return Status.DONE
end

function Plan:do_update(prefix)
	if not self.started then
		player.print(prefix.."Starting "..self.name)
		self.started = true
	end
	local status = self:do_check_status()
	if status == Status.DONE then
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
		if dep_status == Status.BUSY then
			local new_dep_status = dep:do_update(prefix..'-')
			self.updated = false
			if not is_status(new_dep_status) or new_dep_status == Status.BUSY then
				return Status.BUSY
			end
			dep_status = new_dep_status
		end
		if dep_status == Status.DONE then
			if dep.started then
				player.print(prefix..'Finished '..dep.name)
			end
			dep.started = false
			dep.updated = false
		elseif dep_status == Status.WAIT then
			wait = true
		elseif dep_status == Status.ERROR then
			err = true
		end
	end
	if wait then
		return Status.WAIT
	elseif err then
		return Status.ERROR
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
		return Status.BUSY
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
		return Status.DONE
	end
	return Status.BUSY
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
		return Status.BUSY
	end
	if #self.past_positions >= 10 then
		local dist = util.distance(self.past_positions[1], player.position)
		self.past_positions = {}
		if dist < 0.1 then
			local tree = get_nearest_tree()
			if tree ~= nil and entity_distance_to_player(tree) < 1 then
				table.insert(self.deps, ChopTree:new(tree))
				return Status.BUSY
			end
			player.print('stuck')
			self.wander = pick_random(defines.direction)
			self.wander_count = math.random(10, 10 + self.stuck_count)
			self.stuck_count = self.stuck_count + 1
			return Status.BUSY
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
		return Status.DONE
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
	return Status.BUSY
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
	plan.starting_amount = tile.amount
	plan.cur_amount = 0
	plan.deps = {
		MoveNear:new(tile.position, 2),
	}
	return plan
end

function MineOre:check_status()
	if not self.tile.valid or self.cur_amount >= self.amount then
		return Status.DONE
	end
	return Status.BUSY
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
	self.cur_amount = self.starting_amount - self.tile.amount
	return Status.BUSY
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
		return Status.BUSY
	end
	return Status.DONE
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
	return Status.BUSY
end

local SmeltItem = Plan:new_plan_type()

function SmeltItem:new(item, amount, recipe)
	local plan = self.raw_new()
	plan.item = item
	plan.amount = amount
	plan.recipe = recipe
	plan.name = 'SmeltItem('..item..','..amount..')'
	plan.cur_amount = 0

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

function SmeltItem:check_status()
	if self.cur_amount >= self.amount then
		return Status.DONE
	end
	if self.smelter == nil then
		return Status.BUSY
	end
	if self:is_smelter_full() then
		return Status.BUSY
	end
	if self.cur_amount + self:pending_amount() >= self.amount then
		return Status.WAIT
	end
	return Status.BUSY
end

local entity_cache = {}

local GetItem = Plan:new_plan_type()

function SmeltItem:set_smelter()
	if self.smelter ~= nil then
		return true
	end

	-- Check cache
	for _, e in ipairs(entity_cache) do
		if e.name == 'stone-furnace' and not e.is_crafting() then
			self.smelter = e
			return true
		end
	end

	-- Check inventory
	if player_inv_get_item_count('stone-furnace') <= 0 then
		table.insert(self.deps, GetItem:new('stone-furnace', 1))
		return false
	end
	local surf = player.surface
	local pos = surf.find_non_colliding_position('stone-furnace', player.position, 100, 4)
	if pos == nil then
		player.print('cannot find position for stone-furnace')
		return false
	end
	self.smelter = surf.create_entity({
		name = 'stone-furnace',
		position = pos,
		force = player.force,
	})
	table.insert(entity_cache, self.smelter)
	if self.smelter == nil then
		player.print('could not create furnace')
		return false
	end

	if player_inv_remove({ name = 'stone-furnace' }) < 1 then
		player.print('Did not remove item from inventory')
	end
	return true
end

function SmeltItem:go_near_smelter()
	table.insert(self.deps, MoveNear:new(self.smelter.position, 2))
end

function SmeltItem:is_smelter_full()
	local out_inv = self.smelter.get_output_inventory()
	for _, ing in ipairs(self.recipe.ingredients) do
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
				self.cur_amount = self.cur_amount + stack.count
			end
		else
			player.print('cannot empty furnace')
			return false
		end
	end
	return true
end

function SmeltItem:update()
	self:clear_deps()
	if not self:set_smelter() then
		return Status.BUSY
	end

	local near_smelter = entity_distance_to_player(self.smelter) < 3

	local out_inv = self.smelter.get_output_inventory()
	if self:is_smelter_full() or out_inv.get_item_count(self.item) + self.cur_amount >= self.amount then
		if not near_smelter then
			self:go_near_smelter()
			return Status.BUSY
		end
		if not self:empty_smelter() then
			return Status.ERROR
		end

		if self.cur_amount >= self.amount then
			return Status.DONE
		end
	end

	local fuel_inv = self.smelter.get_fuel_inventory()
	if fuel_inv.is_empty() then
		if not near_smelter then
			self:go_near_smelter()
			return Status.BUSY
		end
		local fuel_amount = player_inv_get_item_count('raw-wood')
		if fuel_amount < 1 then
			table.insert(self.deps, GetItem:new('raw-wood', 20))
			return Status.BUSY
		end
		if fuel_amount > 20 then
			fuel_amount = 20
		end
		local stack = {name='raw-wood', count=fuel_amount}
		local insert_amount = fuel_inv.insert(stack)
		if insert_amount > 0 then
			player_inv_remove({name='raw-wood', count=insert_amount})
		else
			player.print('could not fuel furnace')
			return Status.ERROR
		end
	end

	local pending_amount = self:pending_amount()
	if self.cur_amount + pending_amount >= self.amount then
		return Status.WAIT
	end

	-- Feed inputs
	local remaining = self.amount - self.cur_amount
	local remaining_runs = math.ceil(remaining / self.recipe_amount)
	if self.smelter.is_crafting() then
		remaining_runs = remaining_runs - 1
	end
	local in_inv = self.smelter.get_inventory(defines.inventory.furnace_source)
	for _, ing in ipairs(self.recipe.ingredients) do
		local have = in_inv.get_item_count(ing.name)
		local needed = ing.amount * remaining_runs
		if have < needed then
			local want = needed - have
			local player_have = player_inv_get_item_count(ing.name)
			local insert = player_have
			if insert > want then
				insert = want
			end
			if insert > 0 then
				if in_inv.can_insert({name=ing.name, count=insert}) then
					if not near_smelter then
						self:go_near_smelter()
						return Status.BUSY
					end
					insert = in_inv.insert({name=ing.name, count=insert})
					player_inv_remove({name=ing.name, count=insert})
				else
					player.print('cannot insert into furnace')
					return Status.ERROR
				end
			end
			if insert < want then
				table.insert(self.deps, GetItem:new(ing.name, want - insert))
				return Status.BUSY
			end
		end
	end
	-- We
	return Status.WAIT
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
	return player_inv_get_item_count(self.item)
end

function GetItem:check_status()
	if self:get_inv_count() >= self.amount then
		return Status.DONE
	end
	return Status.BUSY
end

function GetItem:craft_update()
	local crafting_count = 0
	if player.crafting_queue ~= nil then
		for _, q in ipairs(player.crafting_queue) do
			if q.recipe == self.recipe.name then
				crafting_count = crafting_count + q.count * self.recipe_amount
			end
		end
	end
	local inv_count = self:get_inv_count()
	if inv_count + crafting_count >= self.amount then
		return Status.WAIT
	end
	-- We must craft now
	local togo = self.amount - inv_count - crafting_count
	local runs = math.ceil(togo / self.recipe_amount)
	local tocraft = player.get_craftable_count(self.recipe.name)
	if tocraft > runs then
		tocraft = runs
	end
	if tocraft > 0 then
		tocraft = player.begin_crafting({count=tocraft, recipe=self.recipe})
	end
	runs = runs - tocraft
	if runs == 0 then
		return Status.WAIT
	end
	-- We need more ingredients
	for _, ing in ipairs(self.recipe.ingredients) do
		table.insert(self.deps, GetItem:new(ing.name, ing.amount * runs))
	end
	return Status.BUSY
end

function GetItem:update()
	self:clear_deps()
	local status = self:check_status()
	if status == Status.DONE then
		return status
	end
	if self.recipe ~= nil then
		if self.recipe.category == nil or self.recipe.category == "crafting" then
			return self:craft_update()
		end
		table.insert(self.deps, SmeltItem:new(self.item, self.amount, self.recipe))
		return Status.BUSY
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
		return Status.ERROR
	end
	return Status.BUSY
end

local MasterPlan = Plan:new_plan_type()

function MasterPlan:new()
	local plan = self.raw_new()
	plan.deps = {
		GetItem:new("iron-axe", 2),
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
	ff_button = player.gui.top.add({type='button', name='ff'})
	ff_button.caption = 'ff'
end)

local paused = false

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
		if game.speed > 1.0 then
			game.speed = 1.0
		else
			game.speed = 10.0
		end
	end
end)

script.on_event(defines.events.on_tick, function(event) -- luacheck: ignore event
	if player == nil or paused or action == nil then
		return
	end

	local status = action:do_update('+')
	if status == Status.DONE then
		action = nil
		player.print("plan done after "..event.tick..' ticks')
	end
end)
