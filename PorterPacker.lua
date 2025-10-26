_addon.name = 'PorterPacker'
_addon.author = 'Ivaar'
_addon.version = '0.0.0.8'
_addon.commands = {'porterpacker','packer','po'}

-- DEBUG MODE: Set to true to enable debug logging, false to disable
local DEBUG_MODE = false

require('pack')
require('sets')
require('logger')
bit = require('bit')
slips = require('slips')
res = require('resources')

local equippable_bags = {[0]='Inventory',[8]='Wardrobe',[10]='Wardrobe2',[11]='Wardrobe3',[12]='Wardrobe4'}
local storing_items = false
local retrieve = {}
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

local function put_away_items(items, bags)
    local inventory = {}
    local count = 0
    for bag_id in pairs(bags) do
        inventory[bag_id] = space_available(bag_id)
    end
    for index, item in ipairs(windower.ffxi.get_items(0)) do
        if items[item.id] and item.status == 0 then
            for bag_id in pairs(bags) do
                if inventory[bag_id] > 0 then
                    count = count + item.count
                    inventory[bag_id] = inventory[bag_id] - 1
                    windower.ffxi.put_item(bag_id, index, item.count)
                    break
                end
            end
        end
    end
    return count
end

local function retrieve_items(items, bags)
    local inventory = space_available(0)
    local count = 0
    for bag_id in pairs(bags) do
        for index, item in ipairs(windower.ffxi.get_items(bag_id)) do
            if items[item.id] and item.status == 0 then
                if inventory == 0 then return count end
                count = count + item.count
                inventory = inventory - 1
                windower.ffxi.get_item(bag_id, index, item.count)
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

local function find_porter_items(bag)
    local slip_tables = {}
    local item_filter = table.length(store) > 0 and store
    for _, item in ipairs(windower.ffxi.get_items(bag)) do
        if item.id ~= 0 and item.status == 0 then
            local slip_id = slips.get_slip_id_by_item_id(item.id)
            if slip_id and not slips.player_has_item(item.id) and
                (not item_filter or item_filter[item.id]) and not retrieve[item.id] and
                (slip_id ~= slips.storages[13] and item.extdata:byte(1) ~= 2 or item.extdata:byte(2)%0x80 >= 0x40 and item.extdata:byte(12) >= 0x80) then

                slip_tables[slip_id] = slip_tables[slip_id] or {}
                slip_tables[slip_id][#slip_tables[slip_id]+1] = item
            elseif slips.items[item.id] then
                slip_tables[item.id] = slip_tables[item.id] or {}
                table.insert(slip_tables[item.id], 1, item)
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
        for slip_id, items in pairs(find_porter_items(0)) do
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
            coroutine.sleep(0.1)  -- Brief delay to ensure dialog is ready
            if state == 2 then  -- Still waiting for confirmation
                debug_log('DEBUG: Sending Enter keypress to auto-confirm storage')
                windower.send_command('setkey enter down')
                coroutine.sleep(0.05)
                windower.send_command('setkey enter up')
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
                if item_id and retrieve[item_id] then
                    debug_log('DEBUG: Found item %d to retrieve at bit position %d', item_id, bit_position)
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

local handled_commands = {
    store = S{'pack','store','repack','swap'},
    retrieve = S{'unpack','retrieve','repack','swap'}
}

windower.register_event('addon command', function(...)
    local commands = {...}
    local player = windower.ffxi.get_player()
    commands[1] = commands[1] and commands[1]:lower()
    
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
        notice(' debug                    - shows debug information and discovered zones (only when debug mode is on)')
        notice(' debugon                  - enables debug mode')
        notice(' debugoff                 - disables debug mode')
        notice(' export | exp [file]      - exports storable items in your current inventory to a .lua file')
        notice(' pack | store [file]      - stores current inventory items, if file is specified only items in the file will be stored')
        notice(' unpack | retrieve [file] - retrieves matching items in the file from a porter moogle. file defaults to Name_JOB.lua or JOB.lua')
        notice(' repack | swap [file]     - stores inventory items not in the file and retrieves matching items. file defaults to Name_JOB.lua or JOB.lua')
    elseif commands[1] == 'export' or commands[1] == 'exp' then
        local str = 'return {\n'
        for _, item in ipairs(windower.ffxi.get_items(0)) do
            if slips.get_slip_id_by_item_id(item.id) and res.items[item.id] then
                str = str .. '    "%s",\n':format(res.items[item.id].name)
            end
        end
        str = str .. '}\n'
        local file_path = windower.addon_path .. '/data/'
        if not windower.dir_exists(file_path) then
            windower.create_dir(file_path)
        end
        commands[2] = commands[2] or 'export_%s_%s':format(player.name, player.main_job)
        local export = io.open(file_path .. commands[2] .. '.lua', "w")
        export:write(str)
        export:close()
        notice('exporting storable inventory to %s.lua':format(commands[2]))
    elseif state ~= 0 or player.status ~= 0 then
        notice('busy state: %d, status: %d':format(state, player.status))
    elseif (handled_commands.retrieve+handled_commands.store):contains(commands[1]) then
        if commands[2] or handled_commands.retrieve:contains(commands[1]) then
            commands[2] = commands[2] or player.main_job
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
        debug_log('DEBUG: Starting porter_trade - storing_items: %s', tostring(storing_items))
        porter_trade()
    end
end)
