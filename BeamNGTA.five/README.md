# BeamNGTA.five

GTA V on foot, inside BeamNG.drive.

Your GTA V story-mode character walks around a BeamNG.drive map: GTA's own animation, ragdoll, voice and guns, on BeamNG's
ground, among BeamNG's cars. You play from the BeamNG window with a GTA-style third-person camera.

GTA V runs in the background and draws only the character, from the same viewpoint as BeamNG's camera. That picture is cut
out and pasted into BeamNG's frame every frame, hidden behind whatever BeamNG has in front of him and with a shadow cast on
BeamNG's world. BeamNG tells GTA where the ground, water, walls and nearby cars are, so he stands, swims, climbs and gets
knocked over in the right places.

**This is a hobby project in progress.** Parts of it are rough or untested; see "Known limits".

Nothing of Rockstar's is in this repository. The character is drawn live by your own copy of the game.

## What you need

- **GTA V**, story mode: Legacy (DirectX 11) or Enhanced (DirectX 12). **Never go online with any of this installed.**
- **BeamNG.drive** (made on 0.39).
- **Script Hook V** and **Script Hook V .NET** (v3) in the GTA folder.
- **ReShade with full add-on support** in both games: 6.8 or newer in BeamNG, 6.7.3 or newer in GTA.
- A PC that can run both games at once.

## Install

| In this repository | Copy to |
|---|---|
| `lua/`, `scripts/`, `ui/`, `vehicles/`, `art/` | `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\unpacked\gtaBridge\` |
| `reshade/beam_overlay.addon64` | `BeamNG.drive\Bin64\` |
| `reshade/GtaOverlay.fx` | `BeamNG.drive\Bin64\reshade-shaders\Shaders\` |
| `reshade/GtaPlaceholder.png` | `BeamNG.drive\Bin64\reshade-shaders\Textures\` |
| `gta/BeamBridge.3.cs` | `Grand Theft Auto V\scripts\` |
| `reshade/gta_capture.addon64` | `Grand Theft Auto V\` (next to the game's exe; for Enhanced that folder is `Grand Theft Auto V Enhanced`) |
| `reshade/GtaKey.fx` | `Grand Theft Auto V\reshade-shaders\Shaders\` |

Then:

1. In BeamNG's ReShade turn on the **GtaOverlay** effect (`reshade/preset_beam.ini` holds the line). GTA needs nothing switched on:
   its add-on turns **GtaKey** on while BeamNG is running and off again when it is not.
2. In GTA's settings: windowed or borderless, **Pause Game On Focus Loss: off**, and do not mute audio on focus loss.
   Textures high, the rest low: only the character is ever seen. On Enhanced: frame generation off.
3. Start GTA and load story mode. Start BeamNG and load a map. The bridge engages by itself once both are running: on foot in BeamNG, you are him.

## Controls (in the BeamNG window)

| | |
|---|---|
| Mouse | look |
| W A S D, Shift | walk, sprint |
| Space | jump, or climb what is in front of him; while aiming: combat roll |
| F | get into / out of the car he is standing at (GTA's animation, BeamNG's door) |
| Hold Tab | weapon wheel (BeamNG's radial menu, weapons where GTA has them); let go on one, or click it |
| Tap Tab | put the gun away / take the last one out |
| Right mouse, left mouse | aim, fire |

Shots land in BeamNG: a streak from the gun, a mark where they hit, a small push on the car, windows break, tires go flat.

## Settings

In BeamNG's console: `extensions.gtaBridge.set("name", value)`. They are saved in `settings/gtaBridge.json`.

| Setting | Default | What it does |
|---|---|---|
| **Camera** | | |
| `thirdPerson` | true | GTA-style chase camera: the mouse looks, the camera follows him |
| `camDist` | 3.2 | metres behind his head |
| `camShoulder` | 0.45 | metres to the right, over the shoulder |
| `camHeight` | 0.2 | metres above his head |
| `camPivotRate` | 12 | how tightly the camera follows (higher is tighter) |
| `camPushOut` | 3 | how slowly the camera eases back out after a wall pushed it in |
| `fovMul` | 1.0 | GTA's field of view as a multiple of BeamNG's; change it if he looks too big or too small |
| `predict`, `predictGain` | true, 0.8 | aim GTA's camera ahead by the measured delay so his picture arrives in step; lower gain is calmer |
| **Movement** | | |
| `runPace` | 1.5 | speed with W (1 walk, 2 GTA's run, 3 sprint) |
| `sprintPace` | 2.5 | speed with Shift held |
| `swim` | true | where BeamNG's water is too deep to stand, he swims |
| `walls` | true | walls and fences near him stop him in GTA too; Space vaults or climbs the ones he can |
| `usePlatform` | true | an invisible floor under him in GTA at BeamNG's ground height |
| **Cars** | | |
| `cars` | true | BeamNG cars near him also exist in GTA as invisible stand-ins: he bumps into them and can get in |
| `carRadius`, `carMax` | 40, 6 | how far around him (m), and how many at most |
| `enterAnim` | true | F: he walks to the door and gets in with GTA's animation before BeamNG switches to driving |
| `doorPush`, `doorPushTime` | 80, 0.4 | extra push on BeamNG's door when he opens it (N), and for how long (s) |
| `doorHold` | 30 | gentle push that keeps the door open afterwards (N) |
| `doorPull`, `doorPullTime` | 130, 0.35 | pull when he shuts it (N), and for how long (s) |
| `busDoorForce` | 150 | city bus: extra pull on each front door cylinder while he gets in (N) |
| `headTop` | 0.17 | top of his head above GTA's head bone (m); change it if he sits low or high in cars |
| `bodyCollide` | true | an invisible physical body in BeamNG, so a car that hits him dents and rides over him |
| `bodyNear`, `bodySpeed` | 15, 2.0 | that body is only out while a car within this many metres moves faster than this (m/s) |
| **Weapon wheel** | | |
| `wheelHold` | 0.18 | Tab held this long (s) opens the wheel; shorter is a tap |
| `wheelSlowMo` | 0.2 | how slowly both games run while the wheel is up (1 = full speed) |
| `wheelGhost` | 0.3 | how solid he stays while a BeamNG wheel menu is drawn over him (0 gone, 1 fully there) |
| **Bullets** | | |
| `bullets` | true | his shots land in BeamNG |
| `bulletRange` | 300 | metres |
| `bulletPush` | 6 | how hard one bullet shoves and dents the panel it hits (0 = none) |
| `bulletHoles` | 80 | how many marks are kept; the oldest go first |
| `holeSize` | 0.018 | radius of a mark (m) |
| `tracer` | 0.12 | how long the streak from the gun stays (s); 0 = none |
| **Look** | | |
| `syncTime` | true | GTA's clock follows BeamNG's time of day |
| `sunFlip` | false | set true if his shadow points the opposite way to BeamNG's shadows |
| `sunTrim` | -24 | extra turn (degrees) between GTA's and BeamNG's directions, so the light on him matches BeamNG's sun; always starts at this value |
| `drawSkeleton` | false | draw his joints as a green stick figure (for debugging) |
| **Connection** | | |
| `autoEngage` | true | take over by itself once a map is loaded and GTA is sending |
| `host`, `gtaPort`, `listenPort` | 127.0.0.1, 47200, 47201 | where the GTA script listens, and where BeamNG listens |
| `staleTimeout` | 1.5 | seconds without word from GTA before he is treated as gone |
| `anchorX`, `anchorY`, `anchorZ` | 5000, 5000, 60 | where in GTA he really is: open sea, nothing else to draw |
| `yawDeg`, `ox`, `oy`, `oz` | 0 | how GTA's coordinates map onto BeamNG's (set by the bridge when it engages) |
| **Older ways of showing him** (off while `compose` is true) | | |
| `compose` | true | paste GTA's picture of him into BeamNG's frame (the way described above) |
| `usePuppet`, `renderBody`, `flipQuat` | true, true, false | show him as a mesh or a mannequin inside BeamNG instead |
| `sendVehicles`, `vehicleRadius`, `vehicleHz`, `maxVehicles` | false, 120, 30, 40 | an older way of sending cars to GTA |

The overlay's look (shadow colour, brightness, water) is in ReShade's own menu in BeamNG, under GtaOverlay.

While BeamNG is not running, GTA's add-on stands by: no capture, no frame cap, GtaKey off, so the game plays as normal.
A picture wider than 1920 or taller than 1200 is scaled down to fit before it is sent. An HDR picture (10-bit, as RenoDX makes it)
is turned into a normal one by GtaKey; its `HdrWhite` and `Hdr` settings are in ReShade's menu in GTA.

Frame pacing is in each game's `ReShade.ini`, under a `[GTABRIDGE]` section:

| Game | Setting | Default | What it does |
|---|---|---|---|
| both | `FpsCap` | 60 | frame rate cap |
| GTA | `FrameLock` | 1 | while BeamNG is running, draw one GTA frame per BeamNG frame; 0 lets GTA run free |
| GTA | `KeepFocus` | 1 | while BeamNG is running, hide from GTA that its window is in the background (it drops to 30 fps otherwise); 0 turns that off |
| BeamNG | `GpuPriority` | 2 | BeamNG's GPU priority: 2 normal, 1 below normal, -1 leave alone |
| BeamNG | `PoseLag` | 0 | set to 1 if GTA turns out to draw from the camera position of one frame earlier |

## How it is put together

| | |
|---|---|
| `lua/ge/extensions/gtaBridge.lua` | BeamNG side: camera, ground / water / walls / cars sent to GTA, doors, weapon wheel, bullets |
| `lua/vehicle/extensions/gtaBullet.lua` | runs inside each car that is shot: finds the hit, breaks glass, pops tires |
| `gta/BeamBridge.3.cs` | GTA side (Script Hook V .NET): moves the character from BeamNG's keys, keeps him on an invisible floor at BeamNG's ground height, draws a bright green box behind him, sends his pose back |
| `reshade/gta_capture.cpp`, `GtaKey.fx` | GTA: cut the character out of the frame (the green backdrop, or depth if switched to that in ReShade's menu) and hand it over through shared memory, in step with BeamNG's frames |
| `reshade/beam_overlay.cpp`, `GtaOverlay.fx` | BeamNG: paste him in, hide him behind what is nearer, cast his shadow |
| `tools/` | self-checks for the maths (`check_*.py`, `check_guns.lua`) and helpers |

The two games talk over UDP on this PC only (ports 47200 to 47202).

**Building the add-ons:** `reshade/*.cpp` are 64-bit DLLs built against ReShade's add-on headers (the `include` folder of
the ReShade source) and renamed to `.addon64`; `beam_overlay` also links `ws2_32`. The ones here were built with clang for
`x86_64-pc-windows-msvc`.

**Self-checks:** `python3 tools/check_ground.py` (and the other `check_*.py`);
`luajit tools/check_guns.lua <BeamNG.drive>/lua/common/mathlib.lua`;
`g++ -o check_pixels tools/check_pixels.cpp && ./check_pixels`.

**Which triangles of a car count as window glass:** `python3 tools/glass_rule.py <folder with that vehicle's .jbeam files>`.

## Known limits

- GTA V Enhanced support is new: the Direct3D 12 capture and the HDR conversion have had little testing.
- Both games at once is heavy, and the character's picture arrives a frame or two after BeamNG's; fast mouse turns show it.
- The combat roll, the footstep sound and the muting of GTA's sea and wind are first attempts and may not work on every setup.
- Which part of a car counts as window glass is worked out from the car's structure and is not exact (`tools/glass_rule.py`
  shows it for a given vehicle).
- A shot marks every car on its line, not only the first. Lamps do not break. Bullet holes are small flat pictures, not real decals.
- Rivers are not water yet (lakes and the sea are). If he is killed outright the bridge does not bring him back.
- While driving a BeamNG car there is no visible driver.
- `vehicles/gta_puppet` is an older way of showing him (a mesh inside BeamNG) and is not used by default. Its model and
  textures come from the game and are not here; `tools/build_rig.py` builds the rig from your own export.

## Not affiliated

Not made or endorsed by Rockstar Games, Take-Two or BeamNG. Script Hook V, Script Hook V .NET and ReShade are other people's
tools: get them from their own pages.
