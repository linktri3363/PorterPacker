_addon.name = 'PorterPacker'
_addon.author = 'Ivaar'
_addon.version = '0.0.1.06'
_addon.commands = {'porterpacker','packer','po'}

-- LINKTRI MODIFICATION (2026-07-05): Merged continuous ("all") mode from Gimlic's fork (v0.0.1.02).
-- Continuous mode pulls storage slips from Satchel/Sack/Case, shuttles storable items from the
-- Wardrobes through inventory, returns slips to the bag they came from, and stows retrieved gear
-- into Wardrobes by priority. The 0x0D keypress-based store confirmation (which preserves the
-- game's correct item-name/count messages) is KEPT; Gimlic's 0x0C packet-rewrite confirm was NOT
-- ported. Fixes applied to the ported code: original_retrieve local-shadowing bug (his filter in
-- find_porter_items was permanently inert), global 'i' leak in the retrieve loop, and slip_used
-- moved from file-level state into the loop that uses it.
-- LINKTRI MODIFICATION (2026-07-05, v0.0.1.04): re-timed continuous mode. All coroutine.sleep
-- calls are now gated on work actually happening (items moved / slip moved), and put_away_items
-- exits immediately when idle instead of retrying 4 x 1s. Pack ('all') runs previously wasted
-- roughly 6-10s of sleeps per slip; the trade pacing itself is unchanged.
-- LINKTRI MODIFICATION (2026-07-05, v0.0.1.05): added addon-managed keybinds for continuous
-- mode (see KEYBINDS table below). Bound on load, released on unload.
-- LINKTRI MODIFICATION (2026-07-05, v0.0.1.06): added STOW_RETRIEVED setting (default false).
-- Retrieved gear now stays in inventory instead of being stowed into Wardrobes; unpacking
-- stops with a warning if inventory fills. Slip round-trips to Satchel/Sack/Case are unchanged.

-- DEBUG MODE: Set to true to enable debug logging, false to disable
local DEBUG_MODE = false

require('pack')
require('sets')
require('logger')
require('coroutine') -- LINKTRI MODIFICATION: coroutine.sleep used by continuous mode (and keypress confirm)
bit = require('bit')
slips = require('slips')
res = require('resources')

-- LINKTRI MODIFICATION: replaced the old (unused) name map with the bag ID list continuous mode
-- scans for slips and storable items. Despite the name, this includes the slip-holding bags
-- (Satchel/Sack/Case) as well as the Wardrobes.
local equippable_bags = {
    0,      -- Inventory
    5,      -- Satchel
    6,      -- Sack
    7,      -- Case
    8,      -- Wardrobe
    10,     -- Wardrobe 2
    11,     -- Wardrobe 3
    12,     -- Wardrobe 4
    13,     -- Wardrobe 5
    14,     -- Wardrobe 6
    15,     -- Wardrobe 7
    16,     -- Wardrobe 8
}

-- LINKTRI MODIFICATION: where continuous mode stows retrieved gear, in order of preference.
local bag_priority = {
    15,     -- Wardrobe 7
    14,     -- Wardrobe 6
    13,     -- Wardrobe 5
    12,     -- Wardrobe 4
    11,     -- Wardrobe 3
    10,     -- Wardrobe 2
    8,      -- Wardrobe
    16,     -- Wardrobe 8
}

-- LINKTRI MODIFICATION: set true to stow retrieved gear into Wardrobes (bag_priority order,
-- Gimlic's original behavior). false = retrieved gear stays in inventory, and unpacking stops
-- with a warning when inventory fills.
local STOW_RETRIEVED = false

-- LINKTRI MODIFICATION: keybinds for continuous mode, registered on load / released on unload.
-- Windower bind modifier symbols: ^ = Ctrl, ! = Alt, @ = Win, ~ = Shift, # = Apps key.
-- Edit the left-hand keys to taste. Note these run the same code path as typing the command,
-- so 'pack all' / 'unpack all' / 'repack all' use the default job file (Name_JOB.lua or
-- JOB.lua) and will abort with an error if no file exists for the current job.
local KEYBINDS = {
    ['^!p'] = 'po pack all',      -- Ctrl+Alt+P : store job-file items from inventory + wardrobes
    ['^!u'] = 'po unpack all',    -- Ctrl+Alt+U : retrieve job-file items into inventory
    ['^!r'] = 'po repack all',    -- Ctrl+Alt+R : store non-file items, retrieve file items
}

local storing_items = false
local continuous = false        -- LINKTRI MODIFICATION: continuous ("all") mode flag
local retrieve = {}
local original_retrieve = {}    -- LINKTRI MODIFICATION: master copy of the retrieve list for continuous
                                -- mode. Gimlic's fork declared a shadowing local inside continuous_porter(),
                                -- which left this file-level table empty forever and made the filter in
                                -- find_porter_items() a no-op. Fixed: continuous_porter() now assigns this upvalue.
local store = {}
local state = 0
local zones = {
    [26]  = 621,    -- Tavnazian Safehold - (F-8)
    [50]  = 959,    -- Aht Urhgan Whitegate - (I-11)
    [53]  = 330,    -- Nashmau - (H-6)
    [80]  = 661,    -- Southern San d'Oria [S] - (M-5)
    [87]  = 603,    -- Bastok Markets [S] - (H-7)
    [94]  = 525,    -- Windurst Waters [S] - (L-10)
    [231] = 874,    -- Northern San d'Oria - (K-8)
    [235] = 547,    -- Bastok Markets - (I-9)
    [240] = 870,    -- Port Windurst - (L-6)
    [245] = 10106,  -- Lower Jeuno - (I-6)
    [247] = 138,    -- Rabao - (G-8)
    [248] = 1139,   -- Selbina - (I-9)
    [249] = 338,    -- Mhaura - (I-8)
    [250] = 309,    -- Kazham - (H-9)
    [252] = 246,    -- Norg - (G-7)
    [256] = 43,     -- Western Adoulin - (H-11)
    [280] = 802,    -- Mog Garden	
	[279] = 13,     -- Odyssey Lobby (alternate zone ID)
	[298] = 13,     -- Odyssey Lobby (Walk of Echoes [P1])
}

-- DEBUG: Track all discovered zone/menu combinations (only when debug mode is on)
local discovered_zones = {}

local function space_available(bag_id)
    local bag = windower.ffxi.get_bag_info(bag_id)
    return bag.enabled and (bag.max - bag.count) or 0
end

-- LINKTRI MODIFICATION: replaced with Gimlic's version, then re-timed (2026-07-05).
-- His retry loop slept 1s x 4 passes whenever nothing matched, treating "nothing to move" the
-- same as "items haven't landed yet". During pack ('all') runs original_retrieve is empty, so
-- every post-trade call burned ~4s doing nothing. Now: empty list or no target space exits
-- immediately, and the not-landed-yet retry is 3 x 0.4s. Stragglers that land later are swept
-- up by the next post-trade call, the low-space stow, or the final stow pass.
local function put_away_items(items, bags)
    if table.length(items) == 0 then
        return 0
    end
    local inventory = {}
    local count = 0
    local target_space = false
    for __, bag_id in pairs(bags) do
        inventory[bag_id] = space_available(bag_id)
        if inventory[bag_id] > 0 then
            target_space = true
        end
    end
    if not target_space then
        return 0
    end
    for attempt = 1, 4 do
        local moved = false
        for index, item in ipairs(windower.ffxi.get_items(0)) do
            if items[item.id] and item.status == 0 then
                for __, bag_id in pairs(bags) do
                    if inventory[bag_id] > 0 and windower.ffxi.get_bag_info(bag_id).enabled and bag_id ~= 0 then
                        moved = true
                        count = count + item.count
                        inventory[bag_id] = inventory[bag_id] - 1
                        windower.ffxi.put_item(bag_id, index, item.count)
                        break
                    end
                end
            end
        end
        if moved or attempt == 4 then
            break
        end
        coroutine.sleep(0.4)
    end
    return count
end

-- LINKTRI MODIFICATION: replaced with Gimlic's version. Signature changed: 'items' is now an
-- ARRAY of item objects (not a set keyed by id), and 'bags' is a list of source bag IDs.
-- Pulls matching items from the listed bags (skipping inventory itself) into inventory.
local function retrieve_items(items, bags)
    local inventory = space_available(0)
    local count = 0
    if #items ~= 0 then
        for n = 1, #items do
            for __, bag_id in pairs(bags) do
                if windower.ffxi.get_bag_info(bag_id).enabled and bag_id ~= 0 then
                    for index, item in ipairs(windower.ffxi.get_items(bag_id)) do
                        if items[n].id == item.id and item.status == 0 then
                            if inventory == 0 then return count end
                            count = count + item.count
                            inventory = inventory - 1
                            windower.ffxi.get_item(bag_id, index, item.count)
                        end
                    end
                end
            end
        end
    end
    return count
end

local function find_item(bags, item_id, count)
    for _, bag_name in pairs(bags) do
        for _, item in ipairs(windower.ffxi.get_items(bag_name)) do
            if item.id == item_id and item.count >= count and item.status == 0 then
                return item
            end
        end
    end
    return nil
end

local function get_trade_items(items)
    local t = {}
    for _, item in ipairs(windower.ffxi.get_items(0)) do
        if items[item.id] and item.count >= items[item.id] and item.status == 0 then
            t[#t+1] = item
            if #t > 7 then
                break
            end
        end
    end
    return #t > 0 and t
end

local function find_npc(name)
    local npc = windower.ffxi.get_mob_by_name(name)
    if npc and math.sqrt(npc.distance) < 6 and npc.valid_target and npc.is_npc and bit.band(npc.spawn_type, 0xDF) == 2 then
        return npc
    end
    error('%s is not in range':format(name))
end

-- Helper function for debug logging
local function debug_log(message, ...)
    if DEBUG_MODE then
        notice(message:format(...))
    end
end

-- Helper function to dump packet bytes for debugging
local function dump_packet_bytes(data, start_pos, end_pos)
    local bytes = {}
    for i = start_pos, end_pos do
        table.insert(bytes, string.format('%02X', data:byte(i)))
    end
    return table.concat(bytes, ' ')
end

local function trade_npc(npc, items)
    debug_log('DEBUG: Trading %d items to %s (ID: %d, Index: %d)', #items, npc.name or 'Unknown', npc.id, npc.index)
    
    -- Enhanced debugging for Odyssey
    if DEBUG_MODE then
        local current_zone = windower.ffxi.get_info().zone
        if current_zone == 298 then
            notice('*** ODYSSEY TRADE ATTEMPT ***')
            notice('NPC Name: %s':format(npc.name or 'nil'))
            notice('NPC ID: %d':format(npc.id))
            notice('NPC Index: %d':format(npc.index))
            notice('NPC Spawn Type: %d':format(npc.spawn_type))
            notice('Items being traded:')
            for i = 1, #items do
                if items[i] and res.items[items[i].id] then
                    notice('  Slot %d: %s (ID: %d, Count: %d)':format(items[i].slot, res.items[items[i].id].name, items[i].id, items[i].count))
                end
            end
        end
    end
    
    local str = 'I2':pack(0, npc.id)
    for x = 1, 8 do
        str = str .. 'I':pack(items[x] and items[x].count or 0)
    end
    str = str .. 'I2':pack(0, 0)
    for x = 1, 8 do
        str = str .. 'C':pack(items[x] and items[x].slot or 0)
    end
    str = str .. 'C2HI':pack(0, 0, npc.index, #items > 8 and 8 or #items)
    windower.packets.inject_outgoing(0x36, str)
    state = 1
    debug_log('DEBUG: State changed to 1 (waiting for menu)')
end

-- LINKTRI MODIFICATION: now takes a LIST of bag IDs instead of a single bag, so continuous mode
-- can scan Wardrobes/Satchel/Sack/Case. Also skips items queued for retrieval this run
-- (original_retrieve) so continuous mode doesn't re-store gear it just pulled out.
local function find_porter_items(bags)
    local slip_tables = {}
    local item_filter = table.length(store) > 0 and store
    for __, bag in ipairs(bags) do
        for _, item in ipairs(windower.ffxi.get_items(bag)) do
            if item.id ~= 0 and item.status == 0 then
                local slip_id = slips.get_slip_id_by_item_id(item.id)
                if slip_id and not slips.player_has_item(item.id) and
                    (not item_filter or item_filter[item.id]) and not retrieve[item.id] and not original_retrieve[item.id] and
                    (slip_id ~= slips.storages[13] and item.extdata:byte(1) ~= 2 or item.extdata:byte(2)%0x80 >= 0x40 and item.extdata:byte(12) >= 0x80) then

                    slip_tables[slip_id] = slip_tables[slip_id] or {}
                    slip_tables[slip_id][#slip_tables[slip_id]+1] = item
                elseif slips.items[item.id] then
                    slip_tables[item.id] = slip_tables[item.id] or {}
                    table.insert(slip_tables[item.id], 1, item)
                end
            end
        end
    end
    return slip_tables
end

local function porter_trade()
    debug_log('DEBUG: porter_trade() called - State: %d, Storing: %s, Retrieve count: %d', state, tostring(storing_items), table.length(retrieve))
    
    local npc = find_npc('Porter Moogle')
    if not npc then
        debug_log('DEBUG: Porter Moogle not found - resetting state')
        retrieve = {}
        store = {}
        storing_items = false
        return
    end
    
    debug_log('DEBUG: Porter Moogle found at distance %.2f', math.sqrt(npc.distance))
    
    if storing_items then
        debug_log('DEBUG: Processing storing items...')
        for slip_id, items in pairs(find_porter_items({0})) do -- LINKTRI MODIFICATION: table arg per new find_porter_items signature
            if #items > 1 and items[1].id == slip_id then
                debug_log('DEBUG: Found slip %d with %d items to store', slip_id, #items)
                return trade_npc(npc, items)
            end
        end
        store = {}
        storing_items = false
        debug_log('DEBUG: Storing complete')
    end
    
    if table.length(retrieve) ~= 0 and space_available(0) ~= 0 then
        debug_log('DEBUG: Processing retrieve items...')
        for slip_id, items in pairs(slips.get_player_items()) do
            if items.n ~= 0 then
                for _, item_id in ipairs(items) do
                    if retrieve[item_id] and not find_item(slips.default_storages, item_id, 1) then
                        debug_log('DEBUG: Need to retrieve item %d from slip %d', item_id, slip_id)
                        local slip_item = find_item({slips.default_storages[1]}, slip_id, 1)
                        if slip_item then
                            debug_log('DEBUG: Trading slip %d to retrieve items', slip_id)
                            return trade_npc(npc, {slip_item})
                        else
                            debug_log('DEBUG: Slip %d not found in inventory', slip_id)
                        end
                    end
                end
            end
        end
    end
    
    retrieve = {}
    debug_log('DEBUG: porter_trade() completed - all operations finished')
end

local function inject_option(npc_id, npc_index, zone_id, menu_id, option_index, bool)
    debug_log('DEBUG: inject_option - NPC: %d, Zone: %d, Menu: %d, Option: %d, Bool: %d', npc_id, zone_id, menu_id, option_index, bool)
    windower.packets.inject_outgoing(0x5B, 'I3H4':pack(0, npc_id, option_index, npc_index, bool, zone_id, menu_id))
    return true
end

local function porter_store(data)
    debug_log('DEBUG: porter_store called')
    
    -- Check if byte 0x0D is 0 (confirmation needed)
    -- Based on debug output, this is the byte that's 0 when confirmation is needed
    if data:byte(0x0D+1) == 0 then
        debug_log('DEBUG: porter_store - confirmation dialog detected at 0x0D, will auto-confirm with Enter')
        
        -- Automatically send Enter keypress to confirm the storage
        -- This preserves the game's original messages (showing correct item names and counts)
        coroutine.schedule(function()
            coroutine.sleep(0.2)  -- Increased delay to ensure dialog is fully ready
            if state == 2 then  -- Still waiting for confirmation
                debug_log('DEBUG: Sending Enter keypress to auto-confirm storage')
                windower.send_command('setkey enter down')
                coroutine.sleep(0.1)  -- Hold enter slightly longer
                windower.send_command('setkey enter up')
            else
                debug_log('DEBUG: State changed before Enter keypress, skipping')
            end
        end, 0)
        
        -- Return the original unmodified data so the game shows correct messages
        return data
    end
    
    debug_log('DEBUG: porter_store - no confirmation needed (byte 0x0D is not 0)')
    return false
end

local function porter_retrieve(data, update, zone_id, menu_id)
    debug_log('DEBUG: porter_retrieve called - Zone: %d, Menu: %d', zone_id, menu_id)
    local npc_id = data:unpack('I', 0x04+1)
    local npc_index = data:unpack('H', 0x28+1)
    if space_available(0) ~= 0 then
        local option_index = 0
        local stored_items = update and update:sub(0x04+1, 0x1B+1) or data:sub(0x08+1, 0x1F+1)
        local slip_number = data:unpack('I', 0x24+1) + 1
        debug_log('DEBUG: porter_retrieve - processing slip %d', slip_number)
        for bit_position = 0, 191 do
            if stored_items:unpack('b', math.floor(bit_position/8)+1, bit_position%8+1) == 1 then
                local item_id = slips.items[slips.storages[slip_number]][bit_position+1]
                if item_id and retrieve[item_id] and space_available(0) ~= 0 then -- LINKTRI MODIFICATION: per-item space check from Gimlic's fork; stops selecting once inventory fills mid-menu
                    if update and bit_position == update:unpack('I', 0x2A+1) then
                        debug_log('DEBUG: Item %d retrieved successfully', item_id)
                        retrieve[item_id] = nil
                    else
                        debug_log('DEBUG: Selecting item %d for retrieval', item_id)
                        return inject_option(npc_id, npc_index, zone_id, menu_id, option_index, 1)
                    end
                end
                option_index = option_index + 1
            end
        end
    end
    debug_log('DEBUG: porter_retrieve - finishing, setting state to 3')
    state = 3
    return inject_option(npc_id, npc_index, zone_id, menu_id, 0x40000000, 0)
end

local events = {}
for i,v in pairs(zones) do
    events[i] = {
        [v-1] = porter_store,
        [v] = porter_retrieve
    }
end

local function check_event(data, update)
    local zone_id, menu_id = data:unpack('H2', 0x2A+1)
    
    -- DEBUG: Log all zone/menu combinations we encounter (only in debug mode)
    if DEBUG_MODE then
        if not discovered_zones[zone_id] then
            discovered_zones[zone_id] = {}
        end
        if not discovered_zones[zone_id][menu_id] then
            discovered_zones[zone_id][menu_id] = true
            local zone_name = res.zones[zone_id] and res.zones[zone_id].name or 'Unknown'
            notice('DEBUG: NEW Zone/Menu discovered - Zone %d (%s), Menu %d':format(zone_id, zone_name, menu_id))
            
            -- Special handling for zone 298 (Odyssey)
            if zone_id == 298 then
                notice('*** ODYSSEY ZONE 298 DETECTED! Menu ID is %d ***':format(menu_id))
                notice('*** Add this line to zones table: [298] = %d, -- Odyssey Lobby ***':format(menu_id))
            end
        end
    end
    
    debug_log('DEBUG: check_event - Zone: %d, Menu: %d, Has Handler: %s', zone_id, menu_id, tostring(events[zone_id] and events[zone_id][menu_id] ~= nil))
    
    if events[zone_id] and events[zone_id][menu_id] then
        if update and update == last_update then
            debug_log('DEBUG: check_event - duplicate update packet ignored')
            return true
        end
        debug_log('DEBUG: check_event - setting state to 2, calling handler')
        state = 2
        last_update = update
        return events[zone_id][menu_id](data, update, zone_id, menu_id)
    else
        debug_log('DEBUG: check_event - NO HANDLER FOUND for Zone %d, Menu %d', zone_id, menu_id)
        if DEBUG_MODE and zone_id == 298 then
            notice('*** This is the missing Odyssey handler! ***')
        end
    end
    return false
end

local function release_event(data, release)
    debug_log('DEBUG: release_event called')
    local zone_id, menu_id = data:unpack('H2', 0x2A+1)
    if menu_id == release:unpack('H', 0x05+1) then
        local npc_id = data:unpack('I', 0x04+1)
        local npc_index = data:unpack('H', 0x28+1)
        debug_log('DEBUG: release_event - releasing menu, resetting state')
        inject_option(npc_id, npc_index, zone_id, menu_id, 0x40000000, 0)
        state = 0
        last_update = nil
        retrieve = {}
        store = {}
        storing_items = false
    end
end

windower.register_event('incoming chunk', function(id, data, modified, injected, blocked)
    local current_zone = windower.ffxi.get_info().zone
    
    if id == 0x034 then
        -- DEBUG: Always log menu packets for analysis (only in debug mode)
        if DEBUG_MODE then
            local zone_id, menu_id = data:unpack('H2', 0x2A+1)
            
            if current_zone == 298 or zone_id == 298 then
                notice('DEBUG: Packet 0x034 in Odyssey - Zone: %d, Menu: %d, State: %d':format(zone_id, menu_id, state))
            end
        end
        
        if state == 1 then
            debug_log('DEBUG: Processing menu packet in state 1')
            return check_event(data)
        end
    elseif id == 0x05C and state == 2 then
        debug_log('DEBUG: Processing update packet 0x05C in state 2')
        check_event(windower.packets.last_incoming(0x34), data)
    elseif id == 0x052 and state ~= 0 then
        debug_log('DEBUG: Processing packet 0x052 in state %d', state)
        if state == 3 then
            debug_log('DEBUG: State 3 - continuing porter operations')
            state = 0
            last_update = nil
            porter_trade()
        elseif state == 2 and data:byte(0x04+1) == 2 then
            debug_log('DEBUG: State 2 - releasing event')
            release_event(windower.packets.last_incoming(0x34), data)
        end
    end
end)

windower.register_event('outgoing chunk', function(id, data, modified, injected, blocked)
    if id == 0x05B and state ~= 0 and not injected then
        debug_log('DEBUG: Manual menu selection detected - setting state to 3')
        state = 3
    end
end)

local function load_file(...)
    local file_names = {...}
    for x = 1, 2 do local file_name = file_names[x]
        local file_path = windower.addon_path .. '/data/' .. file_name ..'.lua'
        if windower.file_exists(file_path) then
            local item_table = dofile(file_path)
            local item_names = {}
            for _, name in pairs(item_table) do
                item_names[name:lower()] = true
            end
            local item_ids = {}
            for id, item in pairs(res.items) do
                if item_names[item.name:lower()] or item_names[item.name_log:lower()] then
                    item_ids[id] = true
                end
            end
            if table.length(item_ids) ~= 0 then
                notice('loaded file: %s.lua':format(file_name))
                return item_ids
            end
            error('unable to load items from %s.lua':format(file_name))
            return nil
        end
    end
    error('no matching file found: "%s.lua"':format(table.concat(file_names, '.lua" "', 1, 2)))
    return nil
end

-- LINKTRI MODIFICATION: poll the packet state machine until the current trade cycle finishes
-- (state returns to 0) or 10 seconds elapse. Note the keypress confirm drives this naturally:
-- the real Enter press emits a genuine (non-injected) 0x05B, the outgoing handler sets state 3,
-- and the following 0x052 resets to 0 and chains porter_trade().
local function wait_for_trades()
    local trade_wait_count = 0
    while state ~= 0 and trade_wait_count < 100 do
        coroutine.sleep(0.1)
        trade_wait_count = trade_wait_count + 1
    end
end

-- LINKTRI MODIFICATION: continuous ("all") mode, ported from Gimlic's fork v0.0.1.02.
-- Runs on the addon-command coroutine and blocks until finished (up to ~80 passes per phase).
-- Phase 1 (store): pulls each slip's storable items from Wardrobes/Satchel/Sack/Case into
-- inventory, trades them, and returns the slip to whichever bag it came from.
-- Phase 2 (retrieve): pulls needed slips into inventory from wherever they live, trades them,
-- stows retrieved gear into Wardrobes via bag_priority, and returns the slips.
local function continuous_porter()
    local npc = find_npc('Porter Moogle')
    if not npc then
        retrieve = {}
        store = {}
        storing_items = false
        return
    end

    debug_log('DEBUG: continuous_porter() started - storing: %s, retrieve count: %d', tostring(storing_items), table.length(retrieve))

    -- Record which bag each slip lives in so it can be put back afterwards
    local Satchel_Slip_table = find_porter_items({5})
    local Sack_Slip_table = find_porter_items({6})
    local Case_Slip_table = find_porter_items({7})

    -- Save a copy of what needs to be returned up front; otherwise items get checked off when
    -- the slip isn't in inventory yet.
    -- LINKTRI MODIFICATION: assigns the file-level upvalue (Gimlic's fork declared a shadowing
    -- local here, which broke the original_retrieve filter in find_porter_items()).
    original_retrieve = {}
    if table.length(retrieve) ~= 0 then
        for k, v in pairs(retrieve) do
            original_retrieve[k] = v
        end
    end

    local All_Table = find_porter_items(equippable_bags)

    -- Phase 1: store items from all accessible bags
    if storing_items then
        local action = true
        local i = 1
        while action do
            action = false
            for slip_id, items in pairs(All_Table) do
                if #items > 1 and items[1].id == slip_id then
                    -- pull this slip's items into inventory
                    if space_available(0) ~= 0 then
                        -- LINKTRI MODIFICATION: only pay the settle delay when items actually moved
                        if retrieve_items(items, equippable_bags) > 0 then
                            coroutine.sleep(2)
                        end
                    end
                    for slip_id2, items2 in pairs(find_porter_items({0})) do
                        if #items2 > 1 and items2[1].id == slip_id2 then
                            action = true
                            -- re-check NPC range before each trade
                            npc = find_npc('Porter Moogle')
                            if not npc then
                                retrieve = {}
                                store = {}
                                storing_items = false
                                return
                            end
                            debug_log('DEBUG: continuous store - trading slip %d with %d items', slip_id2, #items2 - 1)
                            trade_npc(npc, items2)
                            wait_for_trades()
                            if STOW_RETRIEVED then -- LINKTRI MODIFICATION: optional wardrobe stow
                                put_away_items(original_retrieve, bag_priority)
                            end
                        end
                    end

                    -- return the slip to the bag it came from
                    for slip_id2, items2 in pairs(Satchel_Slip_table) do
                        if items2[1].id == slip_id then
                            if put_away_items({[slip_id] = true}, {5}) > 0 then -- LINKTRI MODIFICATION: only wait when the slip actually moved
                                coroutine.sleep(1)
                            end
                        end
                    end
                    for slip_id2, items2 in pairs(Sack_Slip_table) do
                        if items2[1].id == slip_id then
                            if put_away_items({[slip_id] = true}, {6}) > 0 then -- LINKTRI MODIFICATION: only wait when the slip actually moved
                                coroutine.sleep(1)
                            end
                        end
                    end
                    for slip_id2, items2 in pairs(Case_Slip_table) do
                        if items2[1].id == slip_id then
                            if put_away_items({[slip_id] = true}, {7}) > 0 then -- LINKTRI MODIFICATION: only wait when the slip actually moved
                                coroutine.sleep(1)
                            end
                        end
                    end
                elseif #items > 2 and i == 1 then
                    windower.add_to_chat(200, 'Consider getting Storage Slip ' .. slips.get_slip_number_by_id(slip_id) .. '. Found ' .. #items .. ' items that could be stored not in your PorterPacker file.')
                end
            end
            -- the background porter_trade() chain clears 'retrieve' when inventory has no matching
            -- slips; re-queue anything from the master list that is still stored
            for slip_id, items in pairs(slips.get_player_items()) do
                if items.n ~= 0 then
                    for _, item_id in ipairs(items) do
                        if original_retrieve[item_id] then
                            retrieve[item_id] = true
                        end
                    end
                end
            end
            i = i + 1
            if i > 80 then action = false end -- safety valve
        end
    end
    store = {}
    storing_items = false

    -- Phase 2: retrieve items, pulling slips from wherever they live
    if table.length(retrieve) ~= 0 and space_available(0) ~= 0 then
        local i = 1 -- LINKTRI MODIFICATION: was an accidental global in Gimlic's fork
        while table.length(retrieve) > 0 and i < 80 do
            for slip_id, items in pairs(slips.get_player_items()) do
                local slip_used = false -- LINKTRI MODIFICATION: was file-level state in Gimlic's fork; only used here
                if items.n ~= 0 then
                    for _, item_id in ipairs(items) do
                        if retrieve[item_id] and not find_item(slips.default_storages, item_id, 1) then
                            local slip_item = find_item(slips.default_storages, slip_id, 1)
                            if slip_item then -- LINKTRI MODIFICATION: nil guard; Gimlic passed a possibly-empty table through
                                if retrieve_items({[1] = slip_item}, equippable_bags) > 0 then
                                    coroutine.sleep(1)
                                end
                            end
                            slip_item = find_item({slips.default_storages[1]}, slip_id, 1)
                            if slip_item then
                                -- re-check NPC range before each trade
                                npc = find_npc('Porter Moogle')
                                if not npc then
                                    retrieve = {}
                                    store = {}
                                    storing_items = false
                                    return
                                end
                                debug_log('DEBUG: continuous retrieve - trading slip %d', slip_id)
                                trade_npc(npc, {slip_item})
                                wait_for_trades()
                                if STOW_RETRIEVED then -- LINKTRI MODIFICATION: optional wardrobe stow
                                    put_away_items(original_retrieve, bag_priority)
                                end
                                slip_used = true
                            end
                        end
                    end
                end

                if slip_used then
                    -- return the slip to the bag it came from
                    for slip_id2, items2 in pairs(Satchel_Slip_table) do
                        if items2[1].id == slip_id then
                            if put_away_items({[slip_id] = true}, {5}) > 0 then -- LINKTRI MODIFICATION: only wait when the slip actually moved
                                coroutine.sleep(1)
                            end
                        end
                    end
                    for slip_id2, items2 in pairs(Sack_Slip_table) do
                        if items2[1].id == slip_id then
                            if put_away_items({[slip_id] = true}, {6}) > 0 then -- LINKTRI MODIFICATION: only wait when the slip actually moved
                                coroutine.sleep(1)
                            end
                        end
                    end
                    for slip_id2, items2 in pairs(Case_Slip_table) do
                        if items2[1].id == slip_id and find_item({slips.default_storages[1]}, slip_id, 1) then
                            if put_away_items({[slip_id] = true}, {7}) > 0 then -- LINKTRI MODIFICATION: only wait when the slip actually moved
                                coroutine.sleep(1)
                            end
                        end
                    end
                end
            end

            -- trade_npc trades everything as if it's in inventory; re-queue anything from the
            -- master list that is still stored so it isn't lost mid-run
            for slip_id, items in pairs(slips.get_player_items()) do
                if items.n ~= 0 then
                    for _, item_id in ipairs(items) do
                        if original_retrieve[item_id] and not find_item(slips.default_storages, item_id, 1) and not retrieve[item_id] then
                            retrieve[item_id] = true
                        end
                    end
                end
            end
            -- LINKTRI MODIFICATION: with stowing off, a full inventory means retrieval can't
            -- continue - stop cleanly instead of spinning through the remaining passes
            if STOW_RETRIEVED and space_available(0) < 3 then
                coroutine.sleep(1)
                put_away_items(original_retrieve, bag_priority)
                coroutine.sleep(1)
            elseif not STOW_RETRIEVED and space_available(0) == 0 and table.length(retrieve) > 0 then
                windower.add_to_chat(200, 'Inventory full - stopping with ' .. table.length(retrieve) .. ' item(s) still stored.')
                break
            end
            i = i + 1
        end
    end
    -- LINKTRI MODIFICATION: final stow only when stowing is enabled and there was a retrieve list
    if STOW_RETRIEVED and table.length(original_retrieve) ~= 0 then
        coroutine.sleep(1)
        if put_away_items(original_retrieve, bag_priority) > 0 then
            coroutine.sleep(1)
        end
    end
    retrieve = {}
    original_retrieve = {} -- LINKTRI MODIFICATION: clear so normal (non-continuous) runs aren't filtered by a stale list
    debug_log('DEBUG: continuous_porter() completed')
end

local handled_commands = {
    store = S{'pack','store','p','repack','swap','r'},          -- LINKTRI MODIFICATION: added p/r short aliases from Gimlic's fork
    retrieve = S{'unpack','retrieve','u','repack','swap','r'},  -- LINKTRI MODIFICATION: added u/r short aliases from Gimlic's fork
    all = S{'all','a','continuous'}                             -- LINKTRI MODIFICATION: continuous mode triggers
}

windower.register_event('addon command', function(...)
    local commands = {...}
    local player = windower.ffxi.get_player()
    commands[1] = commands[1] and commands[1]:lower()
    -- LINKTRI MODIFICATION: lowered copies of args 2/3 for the 'all' keyword check
    -- (commands[2] itself is left untouched where it names a file)
    local arg2 = commands[2] and commands[2]:lower()
    local arg3 = commands[3] and commands[3]:lower()
    
    if commands[1] == 'debug' then
        if DEBUG_MODE then
            notice('=== DEBUG INFO ===')
            notice('Current Zone: %d (%s)':format(windower.ffxi.get_info().zone, res.zones[windower.ffxi.get_info().zone].name))
            notice('Current State: %d':format(state))
            notice('Storing Items: %s':format(tostring(storing_items)))
            notice('Retrieve Items: %d':format(table.length(retrieve)))
            notice('Store Items: %d':format(table.length(store)))
            notice('')
            notice('=== DISCOVERED ZONES ===')
            for zone_id, menus in pairs(discovered_zones) do
                local zone_name = res.zones[zone_id] and res.zones[zone_id].name or 'Unknown'
                for menu_id in pairs(menus) do
                    local has_handler = events[zone_id] and events[zone_id][menu_id] ~= nil
                    notice('Zone %d (%s), Menu %d - Handler: %s':format(zone_id, zone_name, menu_id, tostring(has_handler)))
                end
            end
            notice('==================')
        else
            notice('Debug mode is currently OFF. To enable: Set DEBUG_MODE = true at the top of the file.')
        end
        return
    elseif commands[1] == 'debugon' then
        DEBUG_MODE = true
        notice('Debug mode ENABLED')
        return
    elseif commands[1] == 'debugoff' then
        DEBUG_MODE = false
        notice('Debug mode DISABLED')
        return
    end
    
    if not player then
    elseif not commands[1] or commands[1] == 'help' then
        notice('Commands: command | alias [optional]')
        notice(' //porterpacker | //packer | //po')
        notice(' debug                                   - shows debug information and discovered zones (only when debug mode is on)')
        notice(' debugon                                 - enables debug mode')
        notice(' debugoff                                - disables debug mode')
        notice(' export | exp [file] [all|a]             - exports storable items to a .lua file; "all" scans every accessible bag')
        notice(' pack | store | p [file] [all|a]         - stores current inventory items, if file is specified only items in the file will be stored')
        notice(' unpack | retrieve | u [file] [all|a]    - retrieves matching items in the file from a porter moogle. file defaults to Name_JOB.lua or JOB.lua')
        notice(' repack | swap | r [file] [all|a]        - stores inventory items not in the file and retrieves matching items. file defaults to Name_JOB.lua or JOB.lua')
        notice(' "all" pulls slips from Satchel/Sack/Case and stores from Wardrobes; retrieved items stay in inventory (STOW_RETRIEVED)')
        notice(' Keybinds: Ctrl+Alt+P = pack all | Ctrl+Alt+U = unpack all | Ctrl+Alt+R = repack all (edit KEYBINDS table to change)')
    elseif commands[1] == 'export' or commands[1] == 'exp' then
        local str = 'return {\n'
        -- LINKTRI MODIFICATION: 'export all' scans every accessible bag instead of just inventory
        local bags = {0}
        if (arg2 and handled_commands.all:contains(arg2)) or (arg3 and handled_commands.all:contains(arg3)) then
            bags = {0,1,2,4,5,6,7,8,9,10,11,12,13,14,15,16}
        end
        for __, bag_id in pairs(bags) do
            for _, item in ipairs(windower.ffxi.get_items(bag_id)) do
                if slips.get_slip_id_by_item_id(item.id) and res.items[item.id] then
                    str = str .. '    "%s",\n':format(res.items[item.id].name)
                end
            end
        end
        str = str .. '}\n'
        local file_path = windower.addon_path .. '/data/'
        if not windower.dir_exists(file_path) then
            windower.create_dir(file_path)
        end
        if arg2 and handled_commands.all:contains(arg2) then
            commands[2] = 'export_%s_%s':format(player.name, player.main_job)
        else
            commands[2] = commands[2] or 'export_%s_%s':format(player.name, player.main_job)
        end
        local export = io.open(file_path .. commands[2] .. '.lua', "w")
        export:write(str)
        export:close()
        notice('exporting storable inventory to %s.lua':format(commands[2]))
    elseif state ~= 0 or player.status ~= 0 then
        notice('busy state: %d, status: %d':format(state, player.status))
    elseif (handled_commands.retrieve+handled_commands.store):contains(commands[1]) then
        -- LINKTRI MODIFICATION: detect continuous ("all") mode from arg 2 or 3
        continuous = (arg2 and handled_commands.all:contains(arg2)) or (arg3 and handled_commands.all:contains(arg3)) or false
        if commands[2] or handled_commands.retrieve:contains(commands[1]) then
            if arg2 and handled_commands.all:contains(arg2) then
                commands[2] = player.main_job -- LINKTRI MODIFICATION: 'all' in the file slot means use the default file
            else
                commands[2] = commands[2] or player.main_job
            end
            local item_ids = load_file(commands[2], '%s_%s':format(player.name, commands[2]))
            if not item_ids then
                return
            elseif handled_commands.retrieve:contains(commands[1]) then
                retrieve = item_ids
                debug_log('DEBUG: Set retrieve items count: %d', table.length(retrieve))
            else
                store = item_ids
                debug_log('DEBUG: Set store items count: %d', table.length(store))
            end
        end
        storing_items = handled_commands.store:contains(commands[1])
        debug_log('DEBUG: Starting porter_trade - storing_items: %s, continuous: %s', tostring(storing_items), tostring(continuous))
        if continuous then
            continuous_porter()
            windower.add_to_chat(200, 'Completed Movements')
        else
            porter_trade()
        end
    end
end)

-- LINKTRI MODIFICATION: register/release the continuous-mode keybinds with the addon lifecycle
windower.register_event('load', function()
    for key, command in pairs(KEYBINDS) do
        windower.send_command('bind %s %s':format(key, command))
    end
    debug_log('DEBUG: keybinds registered')
end)

windower.register_event('unload', function()
    for key in pairs(KEYBINDS) do
        windower.send_command('unbind %s':format(key))
    end
end)
