# PorterPacker

A Windower addon for Final Fantasy XI that automates Porter Moogle interactions for storing and retrieving gear from storage slips.

## Overview

PorterPacker eliminates the tedium of manually selecting items from Porter Moogle menus by automatically trading the appropriate slips and selecting the correct gear based on job-specific files you create. Instead of clicking through menus to retrieve your gear sets, simply run a command and watch your gear appear in your inventory.

## Features

- **Automatic gear retrieval** from storage slips based on job files
- **Automatic gear storage** to appropriate slips
- **Job-specific gear sets** using customizable .lua files
- **Export functionality** to create gear lists from your current inventory
- **Debug mode** for troubleshooting and adding support for new zones
- **Multi-zone support** including Odyssey lobby

## Installation

1. Place `PorterPacker.lua` in your `Windower/addons/` folder
2. Load the addon: `//lua load porterpacker`
3. Create your gear files in `Windower/addons/porterpacker/data/`

## Basic Usage

### Commands
`//porterpacker` or `//packer` or `//po`

```
export|exp [file]      - exports storable items in your current inventory to a .lua file
pack|store [file]      - stores current inventory items, if file is specified only items in the file will be stored
unpack|retrieve [file] - retrieves matching items in the file from a porter moogle. file defaults to Name_JOB.lua or JOB.lua
repack|swap [file]     - stores inventory items not in the file and retrieves matching items. file defaults to Name_JOB.lua or JOB.lua
```

### Creating Gear Files

1. **Export your current gear:**
   ```
   //po export GEO
   ```
   This creates `export_YourName_GEO.lua` containing all storable items in your inventory.

2. **Edit the file** to include only the gear you want for that job.

3. **Save as job-specific file** like `YourName_GEO.lua` or simply `GEO.lua`

### Example Gear File
```lua
return {
    "Jhakri Coronal +2",
    "Jhakri Robe +2", 
    "Jhakri Cuffs +2",
    "Jhakri Slops +2",
    "Jhakri Pigaches +2",
    "Bagua Galero +1",
    "Bagua Tunic +1",
    -- Add more gear as needed
}
```

### Daily Workflow

1. **Before content:** `//po unpack GEO` (retrieves all GEO gear from slips)
2. **After content:** `//po pack` (stores all storable gear back to slips)
3. **Job change:** `//po swap WHM` (stores current gear, retrieves WHM gear)

## Supported Zones

PorterPacker works with Porter Moogles in all major cities and special zones:
- All starting cities (San d'Oria, Bastok, Windurst)  
- Jeuno, Whitegate, Adoulin
- Mog Garden
- **Odyssey Lobby** (Walk of Echoes)
- And many more

## Debug Mode

Debug mode helps troubleshoot issues and add support for new zones with Porter Moogles.

### Enabling Debug Mode

**Method 1: Command (temporary)**
```
//po debugon     - enables debug logging
//po debugoff    - disables debug logging  
//po debug       - shows current debug info
```

**Method 2: File edit (permanent)**
Change line 7 in PorterPacker.lua:
```lua
local DEBUG_MODE = true  -- Set to true for debug logging
```

### Adding New Zones

If you encounter a Porter Moogle in a zone where the addon doesn't work:

1. **Enable debug mode** with `//po debugon`
2. **Try using the addon** in the new zone (e.g., `//po unpack`)
3. **Look for debug messages** like:
   ```
   *** ODYSSEY ZONE 298 DETECTED! Menu ID is 13 ***
   *** Add this line to zones table: [298] = 13, -- Odyssey Lobby ***
   ```
4. **Edit PorterPacker.lua** and add the new zone to the `zones` table around line 33:
   ```lua
   [298] = 13,     -- New Zone Name
   ```
5. **Reload the addon:** `//lua r porterpacker`
6. **Test** to confirm it works

### Debug Output Explained

- **Zone/Menu discovery:** Shows when new Porter Moogle locations are found
- **State tracking:** Shows the addon's internal state during operations
- **Packet analysis:** Shows communication with the game server
- **Item processing:** Shows which items are being stored/retrieved

## Troubleshooting

### Common Issues

**"Porter Moogle is not in range"**
- Stand closer to the Porter Moogle
- Make sure you're targeting the right NPC

**"No matching file found"**
- Check that your gear file exists in `/data/` folder
- Verify the filename matches your job abbreviation
- Use `//po export JOB` to create a template

**"Busy state"** 
- Wait for current operation to complete
- The addon prevents overlapping operations for safety

**Items not retrieving in new zones**
- Enable debug mode to identify missing zone support
- Follow the "Adding New Zones" procedure above

### Files and Locations

```
Windower/
├── addons/
│   └── porterpacker/
│       ├── PorterPacker.lua          # Main addon file
│       └── data/                     # Your gear files
│           ├── GEO.lua               # Job-specific gear
│           ├── YourName_GEO.lua      # Character+job specific
│           └── export_Name_Job.lua   # Exported gear lists
```

## Tips

- **File naming:** Use either `JOB.lua` or `YourName_JOB.lua` formats
- **Regular exports:** Periodically export gear to update your lists as you acquire new items
- **Backup files:** Keep copies of your gear files in case of corruption
- **Test thoroughly:** Always test new gear files with a few items before including your entire set

## Technical Notes

- Works by intercepting and modifying Porter Moogle menu packets
- Requires items to actually be stored in slips to retrieve them
- Will not retrieve items already in your inventory
- Respects inventory space limitations
- Compatible with all storage slip types

## Contributing

If you discover a new zone that needs support, please share the zone ID and menu ID information with the community so it can be added to future versions.