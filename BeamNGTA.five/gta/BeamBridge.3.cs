using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using GTA;
using GTA.Math;
using GTA.Native;

public class BeamBridge : Script
{
    const int ListenPort = 47200;
    const int BeamPort = 47201;
    const double CameraFreshSeconds = 0.5;
    const double ProxyStaleSeconds = 1.0;
    const float VehicleHitMinSpeed = 3.0f;
    const float CameraHeadingSign = 1f;

    const int VK_LBUTTON = 0x01, VK_RBUTTON = 0x02, VK_TAB = 0x09, VK_SPACE = 0x20;
    const int VK_A = 0x41, VK_D = 0x44, VK_E = 0x45, VK_G = 0x47, VK_Q = 0x51, VK_R = 0x52, VK_S = 0x53, VK_W = 0x57;
    const int VK_LSHIFT = 0xA0, VK_LCONTROL = 0xA2;

    static readonly int[] BoneIds = new int[]
    {
        0x2E28,
        0x60F2,
        0x9995,
        0x796E,
        0xFCD9,
        0xB1C5,
        0xEEEB,
        0x49D9,
        0x29D2,
        0x9D4D,
        0x6E5C,
        0xDEAD,
        0xE39F,
        0xF9BB,
        0x3779,
        0xCA72,
        0x9000,
        0xCC4D
    };

    static readonly string[] ProxyModelNames = new string[]
    {
        "bati", "panto", "blista", "asea", "baller", "granger", "bison", "mule", "benson", "bus", "phantom"
    };
    const string PlatformModelName = "trflat";

    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct CURSORINFO { public int cbSize, flags; public IntPtr hCursor; public POINT pt; }
    [DllImport("user32.dll")] static extern bool GetCursorInfo(ref CURSORINFO ci);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr hWnd, ref POINT p);
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);

    class Proxy
    {
        public int BeamId;
        public Vehicle Veh;
        public double LastSeen;
        public Vector3 Velocity;
        public double LastHit;
        public float MinZ;
        public string ModelName = "";
        public bool SeatKnown, SeatOk;
        public Vector3 SeatLocal;
        public Vector3 Half;
        public bool Kinematic;
        public double Created;
    }

    class Candidate
    {
        public Model Model;
        public Vector3 Size;
        public float MinZ;
    }

    UdpClient rx;
    UdpClient tx;
    IPEndPoint anyEp = new IPEndPoint(IPAddress.Any, 0);
    readonly Dictionary<int, Proxy> proxies = new Dictionary<int, Proxy>();
    readonly List<Candidate> candidates = new List<Candidate>();
    readonly Dictionary<string, Candidate> named = new Dictionary<string, Candidate>();
    readonly Stopwatch clock = Stopwatch.StartNew();
    bool modelsReady;

    const string DeckPropName = "stt_prop_stunt_bblock_mdm1";
    Model deckModel;
    bool deckIsProp, deckLongX;
    Vector3 deckMid;
    const int DeckCols = 7, DeckRows = 3;
    readonly Entity[] decks = new Entity[DeckCols * DeckRows];
    readonly Vector3[] deckPos = new Vector3[DeckCols * DeckRows];
    bool decksReady;
    float deckLen = 12f, deckZ;
    float platformWidth = 2.5f;
    Vector3 platformSize;
    bool usePlatform = true;
    Vector3 walkerFeet;
    double lastWalkerPacket = -999;
    bool pinned;
    const float GroundLift = 0f;
    float platCal; int groundedFrames;
    Vector3 tpTarget; bool tpPending;
    const float PedCenterHeight = 1.0f;
    const bool UseVehicleProxies = true;

    float zoff, floorZ; bool floorSet; double zoffHoldUntil = -999, lastGroundTick = -1, zoffJumpAt = -999;
    float waterZ = -9999f; bool swimming, seaFlat; int calmQuad = -1; double swimDbgAt;
    void FlatSea(bool on)
    {
        Function.Call((Hash)0xB96B00E976BE977FUL, on ? 0f : 1f);
        Function.Call((Hash)0xC54A08C85AE4D410UL, on ? 1f : 0f);
        if (!on) return;
        Function.Call((Hash)0x405591EC8FD9096DUL, 0f);
        Function.Call((Hash)0xF751B16FB32ABC1DUL, 0f);
        Function.Call((Hash)0xB3E6360DDE733E82UL, 0f);
        Function.Call((Hash)0x31727907B2C43C55UL, 0f);
        Function.Call((Hash)0xB8F87EAD7533B176UL, 0f);
    }
    void Calm(bool on, Vector3 p)
    {
        if (calmQuad >= 0) { Function.Call((Hash)0xB1252E3E59A82AAFUL, calmQuad); calmQuad = -1; }
        if (on) calmQuad = Function.Call<int>((Hash)0xFDBF4CDBC07E1706UL, p.X - 500f, p.Y - 500f, p.X + 500f, p.Y + 500f, 0f);
    }

    class Barrier { public Entity E, E2; public float PX, PY, X, Y, Top, Heading, Z; public double Seen; public bool Used, Fresh, Solid, Large, Kill; public float TX, TY, HL, NX, NY, CA; }
    static readonly string[] BarrierNames = { "sum_prop_race_barrier_01_sec", "prop_mp_barrier_02b", "prop_barrier_work06a", "prop_barrier_work05" };
    Model barrierModel, barrierModelL; bool barrierOk, barrierLongX, barrierTold, barrierLOk;
    float barrierCX, barrierCY, barrierCXL, barrierCYL, barrierHalfLenL = 9.5f;
    float barrierTop = 1f, barrierMinZ, barrierHeight = 1f, barrierHalfLen = 1.5f, barrierHalfThick = 0.3f;
    readonly Barrier[] barriers = new Barrier[24];
    class Pole { public Entity E; public float X, Y, Base; public double Seen; public bool Active; }
    readonly Pole[] poles = new Pole[12];
    Model poleModel; bool poleOk; float poleMinZ, poleCX, poleCY;
    class Cand { public Model M; public float L, W, H, CX, CY, MinZ; public bool LongX; public int Kinds; }
    readonly List<Cand> objCands = new List<Cand>();
    class WObj { public List<Entity> Es = new List<Entity>(); public double Seen; public float X, Y, Z, TX, TY, SX, SY, SZ, ZOff; public int Kind; }
    readonly Dictionary<int, WObj> wobjs = new Dictionary<int, WObj>();
    static readonly string[] CandNames = {
        "4:prop_fnclink_02a", "4:prop_fnclink_02b", "4:prop_fnclink_02c", "4:prop_fnclink_02d", "4:prop_fnclink_02e", "4:prop_fnclink_02f", "4:prop_fnclink_02g",
        "4:prop_fnclink_01a", "4:prop_fnclink_01b", "4:prop_fnclink_01c", "4:prop_fnclink_01d", "4:prop_fnclink_01e", "4:prop_fnclink_01f", "4:prop_fnclink_01h", "4:prop_fnclink_03c", "4:02gate3_l",
        "8:prop_postbox_01a",
        "16:prop_elecbox_11", "16:prop_elecbox_13", "48:m24_2_prop_m42_elecbox_01a",
        "32:prop_box_wood03a", "32:prop_box_wood07a", "32:prop_box_wood06a", "32:h4_prop_h4_boxpile_01b", "32:prop_aircon_m_02",
        "32:hei_prop_heist_wooden_box", "32:prop_conc_blocks01a", "32:m25_2_prop_m52_table_square_01a"
    };

    Vector3 camForward;
    Vector3 kPos, kFwd; float kFov = 50f; double lastK = -999;
    int scriptCam; bool camOn;
    float beamHour = -1f; double lastClockSet = -999; bool weatherSet;
    const bool ShowDebug = false;
    double lastCamPacket = -999;
    double lastDbg;
    bool tasked;
    bool riding;
    float runPace = 1.5f;
    float sprintPace = 2.5f;
    bool spaceWas; double jumpAt = -999; bool climbing;
    bool deadTold;

    static readonly string[] Loadout = { "WEAPON_UNARMED", "WEAPON_PISTOL", "WEAPON_SMG", "WEAPON_CARBINERIFLE", "WEAPON_PUMPSHOTGUN" };
    int weaponIdx, gunMode; bool tabWas, loadoutGiven; Entity aimMarker; double gunTaskAt;
    int wantWeapon = -1, shots; float wantSlow = 1f, slowSet = 1f; double tabAt, shotAt; bool wheelCentred;
    double gunDirX, gunDirY;

    const string RollDict = "move_strafe@roll";
    double rollUntil = -999, rollCheckAt = -999, rollNextAt = -999; string rollClip, rollNext;

    void StartRoll(Ped ped, float mx, float my)
    {
        if (!Function.Call<bool>(Hash.HAS_ANIM_DICT_LOADED, RollDict)) return;
        string way = my > 0f ? "bwd_p{0}_180" : my < 0f ? "fwd_p{0}_00" : mx > 0f ? "fwd_p{0}_90" : mx < 0f ? "fwd_p{0}_-90" : "fwd_p{0}_00";
        string first = "combatroll_" + string.Format(way, 1);
        float len1 = Function.Call<float>(Hash.GET_ANIM_DURATION, RollDict, first);
        Function.Call(Hash.TASK_PLAY_ANIM, ped, RollDict, first, 8f, -8f, -1, 0, 0f, false, false, false);
        rollNext = "combatroll_" + string.Format(way, 2);
        float len2 = Function.Call<float>(Hash.GET_ANIM_DURATION, RollDict, rollNext);
        rollNextAt = Now() + Math.Max(0.2, len1 - 0.05);
        rollUntil = Now() + Math.Max(0.6, Math.Min(2.5, len1 + len2));
        rollClip = first; rollCheckAt = Now() + 0.2;
        gunMode = 0; tasked = false;
    }

    const string QuietScene = "FBI_HEIST_H5_MUTE_AMBIENCE_SCENE";
    const string StepMaterial = "AM_BASE_CONCRETE";
    bool quiet; double quietAt = -999;

    void Quiet(bool on)
    {
        if (on)
        {
            Function.Call(Hash.SET_WIND, 0f);
            Function.Call(Hash.SET_WIND_SPEED, 0f);
            if (Now() - quietAt < 1.0) return;
            quietAt = Now();
            if (!Function.Call<bool>(Hash.IS_AUDIO_SCENE_ACTIVE, QuietScene)) Function.Call(Hash.START_AUDIO_SCENE, QuietScene);
            Function.Call(Hash.OVERRIDE_PLAYER_GROUND_MATERIAL, Function.Call<int>(Hash.GET_HASH_KEY, StepMaterial), true);
            quiet = true;
        }
        else if (quiet)
        {
            Function.Call(Hash.STOP_AUDIO_SCENE, QuietScene);
            Function.Call(Hash.OVERRIDE_PLAYER_GROUND_MATERIAL, Function.Call<int>(Hash.GET_HASH_KEY, StepMaterial), false);
            Function.Call(Hash.SET_WIND, -1f);
            Function.Call(Hash.SET_WIND_SPEED, -1f);
            quiet = false; quietAt = -999;
        }
    }

    static bool CentreWheelPointer()
    {
        try
        {
            CURSORINFO ci = new CURSORINFO();
            ci.cbSize = Marshal.SizeOf(typeof(CURSORINFO));
            if (!GetCursorInfo(ref ci) || (ci.flags & 1) == 0 || ci.hCursor == IntPtr.Zero) return false;
            IntPtr w = GetForegroundWindow();
            RECT r; POINT p = new POINT();
            if (!GetClientRect(w, out r) || !ClientToScreen(w, ref p)) return false;
            SetCursorPos(p.X + (r.Right - r.Left) / 2, p.Y + (int)((r.Bottom - r.Top) * 0.55));
        }
        catch (Exception) { }
        return true;
    }

    double nextShot;
    bool GunTasks(Ped ped, float mx, float my, double camHeading, bool jumping)
    {
        bool want = weaponIdx > 0 && !swimming && !jumping && !ped.IsRagdoll && !Down(VK_TAB) && (Down(VK_RBUTTON) || Down(VK_LBUTTON)) && kFwd.Length() > 0.1f;
        if (want && (aimMarker == null || !aimMarker.Exists()))
        {
            Model mm = new Model("prop_golf_ball");
            if (!mm.IsLoaded) { mm.Request(); want = false; }
            else
            {
                aimMarker = World.CreateProp(mm, ped.Position, false, false);
                if (aimMarker == null) want = false;
                else
                {
                    aimMarker.IsPersistent = true; aimMarker.IsVisible = false; aimMarker.IsPositionFrozen = true;
                    Function.Call(Hash.SET_ENTITY_COLLISION, aimMarker, false, false);
                }
            }
        }
        if (!want)
        {
            if (gunMode != 0) { Function.Call(Hash.CLEAR_PED_TASKS, ped); gunMode = 0; tasked = false; }
            return false;
        }
        Vector3 fw = kFwd / kFwd.Length();
        Function.Call(Hash.SET_ENTITY_COORDS_NO_OFFSET, aimMarker, kPos.X + fw.X * 40f, kPos.Y + fw.Y * 40f, kPos.Z - zoff + fw.Z * 40f, false, false, false);
        bool shoot = Down(VK_LBUTTON), moving = mx != 0f || my != 0f;
        int mode = moving ? 3 : (shoot ? 2 : 1);
        double dx = 0.0, dy = 0.0;
        if (moving)
        {
            double h = camHeading * Math.PI / 180.0;
            dx = -Math.Sin(h) * -my + Math.Cos(h) * mx; dy = Math.Cos(h) * -my + Math.Sin(h) * mx;
            double len = Math.Sqrt(dx * dx + dy * dy); dx /= len; dy /= len;
        }
        bool turned = moving && dx * gunDirX + dy * gunDirY < 0.94;
        if (mode != gunMode || turned || Now() - gunTaskAt > (moving ? 8.0 : 2.0))
        {
            int fullAuto = Function.Call<int>(Hash.GET_HASH_KEY, "FIRING_PATTERN_FULL_AUTO");
            bool aimed = gunMode != 0;
            if (moving)
            {
                Vector3 p = ped.Position;
                Function.Call(Hash.TASK_GO_TO_COORD_WHILE_AIMING_AT_ENTITY, ped, p.X + (float)dx * 30f, p.Y + (float)dy * 30f, p.Z, aimMarker, Down(VK_LSHIFT) ? sprintPace : runPace, false, 0.5f, 0f, false, 0, false, fullAuto, 20000);
            }
            else if (shoot) Function.Call(Hash.TASK_SHOOT_AT_ENTITY, ped, aimMarker, 3000, fullAuto);
            else Function.Call(Hash.TASK_AIM_GUN_AT_ENTITY, ped, aimMarker, 3000, aimed);
            gunMode = mode; gunTaskAt = Now(); tasked = true; gunDirX = dx; gunDirY = dy;
        }
        if (moving && shoot && Now() >= nextShot)
        {
            nextShot = Now() + (weaponIdx >= 2 ? 0.1 : 0.28);
            Function.Call(Hash.SET_PED_SHOOTS_AT_COORD, ped, kPos.X + fw.X * 40f, kPos.Y + fw.Y * 40f, kPos.Z - zoff + fw.Z * 40f, true);
        }
        return true;
    }
    bool enterPending; int enterId; double enterAt = -999; bool entering; Vehicle enterVeh;
    Proxy enterProxy; double seatedAt = -999;

    double ragdollUntil = -999;
    readonly Dictionary<string, Vector3> eyeByModel = new Dictionary<string, Vector3>();
    static readonly Vector3 DefaultEye = new Vector3(0f, -0.10f, 0.60f);
    uint beamPid;
    double lastFocusCheck = -999;
    bool beamFocused;
    int seq;
    bool announced;

    public BeamBridge()
    {
        Aborted += (s, e) => { try { if (caster != null) caster.Delete(); } catch (Exception) { } };
        try
        {
            rx = new UdpClient(new IPEndPoint(IPAddress.Loopback, ListenPort));
            rx.Client.Blocking = false;
            tx = new UdpClient();
        }
        catch (Exception ex)
        {
            GTA.UI.Screen.ShowSubtitle("BeamBridge: cannot open UDP " + ListenPort + ": " + ex.Message, 6000);
            return;
        }
        Interval = 0;
        Tick += OnTick;
        Aborted += OnAborted;
    }

    Stopwatch tickWatch = new Stopwatch();
    long tickTotal; int tickCount;
    void OnTick(object sender, EventArgs e)
    {
        tickWatch.Restart();
        TickBody();
        tickTotal += tickWatch.ElapsedTicks;
        if (++tickCount >= 300)
        {
            try
            {
                System.IO.File.AppendAllText("scripts\\BeamBridge.perf.log", string.Format(CultureInfo.InvariantCulture, "{0:HH:mm:ss} script {1:0.00} ms per frame\r\n", DateTime.Now, tickTotal * 1000.0 / Stopwatch.Frequency / tickCount));
            }
            catch { }
            tickTotal = 0; tickCount = 0;
        }
    }

    void TickBody()
    {
        if (!announced)
        {
            announced = true;
        }
        if (!modelsReady) { PrepareModels(); return; }

        Ped ped = Game.Player.Character;
        if (ped == null || !ped.Exists()) return;

        Function.Call(Hash.HIDE_HUD_AND_RADAR_THIS_FRAME);
        ReceiveAll();
        UpdateEnter(ped);
        MovingProxies();
        UpdateGround(ped);
        UpdateBarriers();
        UpdatePoles();
        UpdateObjs();
        PinPed(ped);
        InjectInput(ped);
        SendState(ped);
        float slowNow = Now() - lastK > 2.0 ? 1f : wantSlow;
        if (slowNow < 0.999f || slowSet < 0.999f) { Function.Call(Hash.SET_TIME_SCALE, slowNow); slowSet = slowNow; }
        UpdatePlatform(ped);
        UpdateCamera();
        UpdateCaster(ped);
        UpdateHazards(ped);
        UpdateClock();
        ExpireProxies();
    }

    void PinPed(Ped ped)
    {
        if (tpPending)
        {
            tpPending = false;
            Game.Player.CanControlCharacter = true;
            ped.Task.ClearAllImmediately();
            Function.Call(Hash.REQUEST_COLLISION_AT_COORD, tpTarget.X, tpTarget.Y, tpTarget.Z);
            Function.Call(Hash.SET_ENTITY_COORDS_NO_OFFSET, ped, tpTarget.X, tpTarget.Y, tpTarget.Z + PedCenterHeight + 0.05f, false, false, false);
            ped.Velocity = Vector3.Zero;
            groundedFrames = 0;
            Dbg("put on the anchor");
            floorZ = tpTarget.Z; floorSet = true; zoff = 0f; swimming = false; Calm(false, Vector3.Zero); zoffHoldUntil = Now() + 0.3;
            entering = false;
            enterPending = false;
        }
        bool fresh = Now() - lastWalkerPacket < 0.5;
        bool justEngaged = fresh && !pinned;
        pinned = fresh;
        ped.IsPositionFrozen = false;
        Quiet(fresh);
        if (!fresh)
        {
            ped.HasGravity = true;
            if (seaFlat) { FlatSea(false); Calm(false, Vector3.Zero); seaFlat = false; }
            return;
        }
        FlatSea(true); seaFlat = true;
        Function.Call((Hash)0x95E3D6257B166CF2UL, 0f);
        Function.Call((Hash)0x245A6883D966D537UL, 0f);
        Function.Call((Hash)0xB3B3359379FE77D3UL, 0f);
        Function.Call((Hash)0xEAE6DCC7EEE3DB1DUL, 0f);
        Function.Call((Hash)0x7A556143A1C03898UL, 0f, 0f);
        if (justEngaged)
        {
            Game.Player.CanControlCharacter = true;
            ped.Task.ClearAllImmediately();
            if (!floorSet) { floorZ = walkerFeet.Z; floorSet = true; zoff = 0f; }
            swimming = false; Calm(false, Vector3.Zero);
            if (!loadoutGiven)
            {
                loadoutGiven = true;
                for (int i = 1; i < Loadout.Length; i++)
                {
                    int wh = Function.Call<int>(Hash.GET_HASH_KEY, Loadout[i]);
                    Function.Call(Hash.GIVE_WEAPON_TO_PED, ped, wh, 9999, false, false);
                    Function.Call(Hash.SET_PED_INFINITE_AMMO, ped, true, wh);
                }
                Function.Call(Hash.SET_CURRENT_PED_WEAPON, ped, Function.Call<int>(Hash.GET_HASH_KEY, Loadout[0]), true);
                weaponIdx = 0;
            }
            Function.Call(Hash.SET_ENTITY_COORDS_NO_OFFSET, ped, ped.Position.X, ped.Position.Y, floorZ + PedCenterHeight + 0.05f, false, false, false);
            ped.Velocity = Vector3.Zero;
            ped.HasGravity = true;
        }
        Function.Call(Hash.SET_PED_STEERS_AROUND_VEHICLES, ped, false);
        Function.Call(Hash.SET_PED_STEERS_AROUND_OBJECTS, ped, false);
        Function.Call(Hash.SET_PED_STEERS_AROUND_PEDS, ped, false);
        if (entering || ped.IsInVehicle()) return;
        ped.CanRagdoll = ped.IsRagdoll || Now() < ragdollUntil || MovingProxyNear(ped);
        ped.IsInvincible = false;
        Function.Call(Hash.SET_PED_MAX_HEALTH, ped, 9000);
        Function.Call(Hash.SET_PED_SUFFERS_CRITICAL_HITS, ped, false);
        Function.Call(Hash.SET_PED_DIES_IN_WATER, ped, false);
        Function.Call(Hash.SET_PED_MAX_TIME_UNDERWATER, ped, 100000f);
        Function.Call(Hash.DISABLE_PED_PAIN_AUDIO, ped, false);
        Function.Call(Hash.SET_MAX_WANTED_LEVEL, 0);
        if (ped.IsDead && !deadTold) { deadTold = true; Dbg("he was killed outright: GTA will respawn him away from the anchor"); }
        ped.HasGravity = true;
        float tz = floorZ + PedCenterHeight;
        Vector3 pp = ped.Position;
        if (swimming) return;
bool standing = !ped.IsInAir && !ped.IsRagdoll && decksReady && !NearProxy(ped)
&& Now() - jumpAt > 3.0 && !Flag(Hash.IS_PED_CLIMBING, ped) && Now() > ragdollUntil + 2.5 && !NearBarrier(ped, false);
        groundedFrames = (standing && Math.Abs(ped.Velocity.Z) < 0.3f) ? groundedFrames + 1 : 0;
        if (groundedFrames > 15 && Math.Abs(tz - pp.Z) > 0.08f && Math.Abs(tz - pp.Z) < (deckIsProp ? 0.15f : 8f) && Now() - zoffJumpAt > 3.0)
        {
            platCal = Math.Max(-8f, Math.Min(8f, platCal + (tz - pp.Z)));
            Dbg(string.Format(CultureInfo.InvariantCulture, "floor height corrected by {0:0.00} (total {1:0.00})", tz - pp.Z, platCal));
            Function.Call(Hash.SET_ENTITY_COORDS_NO_OFFSET, ped, pp.X, pp.Y, tz + 0.03f, false, false, false);
            ped.Velocity = Vector3.Zero;
            groundedFrames = 0;
            return;
        }
        if (!ped.IsRagdoll && Now() > ragdollUntil && pp.Z < tz - 0.12f && pp.Z > tz - 3f)
        {
            Function.Call(Hash.SET_ENTITY_COORDS_NO_OFFSET, ped, pp.X, pp.Y, tz, false, false, false);
            var vv = ped.Velocity; ped.Velocity = new Vector3(vv.X, vv.Y, 0f);
            return;
        }
        if (pp.Z < tz - (ped.IsRagdoll || Now() < ragdollUntil ? 2.5f : 0.6f) || pp.Z > tz + 300f)
        {
            Dbg(string.Format(CultureInfo.InvariantCulture, "lifted back: z {0:0.00} wanted {1:0.00} decks {2} ragdoll {3}", pp.Z, tz, decksReady, ped.IsRagdoll));
            Function.Call(Hash.SET_ENTITY_COORDS_NO_OFFSET, ped, pp.X, pp.Y, tz, false, false, false);
            var v = ped.Velocity; ped.Velocity = new Vector3(v.X, v.Y, 0f);
        }
    }
    const float LeashGain = 5f;
    const float LeashSnap = 2.5f;

    static readonly int[] BackdropTris = { 0, 1, 2, 2, 1, 3, 4, 6, 5, 5, 6, 7, 0, 4, 1, 1, 4, 5, 2, 3, 6, 6, 3, 7, 0, 2, 4, 4, 2, 6, 1, 5, 3, 3, 5, 7 };
    static Vector3 BackdropCorner(Vector3 c, int i)
    {
        const float r = 8f;
        return new Vector3(c.X + ((i & 1) != 0 ? r : -r), c.Y + ((i & 2) != 0 ? r : -r), c.Z + ((i & 4) != 0 ? r : -r));
    }
    void DrawBackdrop(Vector3 c)
    {
        for (int i = 0; i < BackdropTris.Length; i += 3)
        {
            Vector3 a = BackdropCorner(c, BackdropTris[i]), b = BackdropCorner(c, BackdropTris[i + 1]), d = BackdropCorner(c, BackdropTris[i + 2]);
            Function.Call(Hash.DRAW_POLY, a.X, a.Y, a.Z, b.X, b.Y, b.Z, d.X, d.Y, d.Z, 0, 255, 0, 255);
            Function.Call(Hash.DRAW_POLY, a.X, a.Y, a.Z, d.X, d.Y, d.Z, b.X, b.Y, b.Z, 0, 255, 0, 255);
        }
    }
    Entity caster;
    Model casterModel;
    bool casterWant, casterTold;
    Vector3 casterDir;
    double casterAt = -999, sweepAt;
    bool casterTold2;
    double offSince;
    void UpdateCaster(Ped ped)
    {
        bool want = casterWant && Now() - casterAt < 1.0 && casterDir.Z > 0.25f && Now() - lastK < 0.5;
        if (want) offSince = 0; else if (offSince == 0) offSince = Now();
        bool on = want || (caster != null && offSince > 0 && Now() - offSince < 3.0 && casterWant);
        if (caster != null && !caster.Exists()) caster = null;
        if (casterModel.IsValid && Now() - sweepAt > 2.0)
        {
            sweepAt = Now();
            foreach (Prop o in World.GetNearbyProps(ped.Position, 400f, casterModel))
                if (caster == null || o.Handle != caster.Handle) o.Delete();
        }
        if (!on)
        {
            if (caster != null) { caster.Delete(); caster = null; }
            return;
        }
        if (caster == null)
        {
            if (!casterModel.IsValid) casterModel = new Model("stt_prop_stunt_bblock_huge_05");
            if (!casterModel.IsValid) { if (!casterTold) { casterTold = true; Dbg("shade: slab model not found"); } return; }
            if (!casterModel.IsLoaded) { casterModel.Request(); return; }
            caster = World.CreateProp(casterModel, ped.Position + new Vector3(0f, 0f, 60f), false, false);
            if (caster == null) return;
            caster.IsInvincible = true;
            caster.IsPersistent = true;
            caster.IsPositionFrozen = true;
            Function.Call(Hash.SET_ENTITY_COLLISION, caster, false, false);
            Dbg("shade: slab created");
        }
        Vector3 d = casterDir / casterDir.Length();
        Vector3 lo, hi;
        casterModel.GetDimensions(out lo, out hi);
        Vector3 p = ped.Position;
        bool far = false;
        for (float t = 60f; t <= 400f && !far; t += 10f)
        {
            p = ped.Position + d * t;
            far = BoxDist(p + lo, p + hi, ped.Position) > 40f && BoxDist(p + lo, p + hi, kPos) > 40f;
        }
        if (!casterTold2) { casterTold2 = true; Dbg("shade: slab dims " + lo + " " + hi); }
        if (!far) { caster.Delete(); caster = null; casterAt = -999; Dbg("shade: slab too near, deleted"); return; }
        Function.Call(Hash.SET_ENTITY_COORDS_NO_OFFSET, caster, p.X, p.Y, p.Z, false, false, false);
        if ((caster.Position - ped.Position).Length() < 60f || (caster.Position - kPos).Length() < 60f) { caster.Delete(); caster = null; Dbg("shade: slab near, deleted"); }
    }
    float BoxDist(Vector3 a, Vector3 b, Vector3 q)
    {
        float dx = Math.Max(Math.Max(a.X - q.X, q.X - b.X), 0f), dy = Math.Max(Math.Max(a.Y - q.Y, q.Y - b.Y), 0f), dz = Math.Max(Math.Max(a.Z - q.Z, q.Z - b.Z), 0f);
        return (float)Math.Sqrt(dx * dx + dy * dy + dz * dz);
    }
    double fireUntil, fireRagAt, boomAt = -999;
    bool onFire;
    double fireTry, fireSpotAt = -999, fireSpawnAt = -999;
    Vector3 fireSpot;
    int fireHandle;
    Vector3 boomPos;
    void UpdateHazards(Ped ped)
    {
        double now = Now();
        if (boomAt > 0 && now - boomAt < 0.5 && boomAt != -999)
        {
            Vector3 pc = ped.Position;
            Vector3 dir = new Vector3(pc.X - boomPos.X, pc.Y - boomPos.Y, 0f);
            if (dir.Length() < 0.2f) dir = new Vector3(0f, 1f, 0f);
            dir.Normalize();
            Vector3 at = pc - dir * 2f;
            boomAt = -999;
            ragdollUntil = now + 5.0;
            ped.CanRagdoll = true;
            Function.Call(Hash.ADD_EXPLOSION, at.X, at.Y, at.Z - 0.5f, 7, 1f, true, false, 1.5f, false);
            Function.Call(Hash.SET_PED_TO_RAGDOLL, ped, 4000, 4000, 0, false, false, false);
            ped.Velocity = dir * 14f + new Vector3(0f, 0f, 8f);
            Dbg("car exploded next to him");
        }
        if (now < fireUntil)
        {
            if (!Function.Call<bool>(Hash.IS_ENTITY_ON_FIRE, ped))
            {
                Function.Call(Hash.SET_ENTITY_PROOFS, ped, false, false, false, false, false, false, false, false);
                int fh = Function.Call<int>(Hash.START_ENTITY_FIRE, ped);
                if (now - fireTry > 1.0)
                {
                    fireTry = now;
                    Vector3 fp = ped.Position;
                    Function.Call(Hash.ADD_EXPLOSION, fp.X, fp.Y, fp.Z - 0.3f, 3, 1f, true, false, 0f, false);
                    Dbg("setting him on fire handle=" + fh + " burning=" + Function.Call<bool>(Hash.IS_ENTITY_ON_FIRE, ped) + " health=" + ped.Health + " dead=" + ped.IsDead + " water=" + ped.IsInWater);
                }
            }
            onFire = true;
            ragdollUntil = Math.Max(ragdollUntil, now + 0.3);
        }
        else if (onFire)
        {
            onFire = false;
            Function.Call(Hash.STOP_ENTITY_FIRE, ped);
        }
    }
    void UpdateCamera()
    {
        if (Now() - lastK < 0.5)
        {
            float len = kFwd.Length();
            if (len < 1e-4f) return;
            Vector3 fw = kFwd / len;
            float yaw = (float)(Math.Atan2(-fw.X, fw.Y) * 180.0 / Math.PI);
            float pitch = (float)(Math.Asin(Math.Max(-1f, Math.Min(1f, fw.Z))) * 180.0 / Math.PI);
            if (scriptCam == 0 || !Function.Call<bool>(Hash.DOES_CAM_EXIST, scriptCam))
            {
                scriptCam = Function.Call<int>(Hash.CREATE_CAM, "DEFAULT_SCRIPTED_CAMERA", true);
                camOn = false;
            }
            Function.Call(Hash.SET_CAM_COORD, scriptCam, kPos.X, kPos.Y, kPos.Z - zoff);
            Function.Call(Hash.SET_CAM_ROT, scriptCam, pitch, 0f, yaw, 2);
            Function.Call(Hash.SET_CAM_FOV, scriptCam, kFov);
            Function.Call(Hash.SET_CAM_FAR_CLIP, scriptCam, 16f);
            DrawBackdrop(new Vector3(kPos.X, kPos.Y, kPos.Z - zoff));
            if (!camOn)
            {
                Function.Call(Hash.SET_CAM_ACTIVE, scriptCam, true);
                Function.Call(Hash.RENDER_SCRIPT_CAMS, true, false, 0, true, false);
                camOn = true;
            }
        }
        else if (camOn)
        {
            Function.Call(Hash.RENDER_SCRIPT_CAMS, false, false, 0, true, false);
            camOn = false;
        }
    }

    void UpdateClock()
    {
        if (beamHour < 0f) return;
        double now = Now();
        if (now - lastClockSet < 1.0) return;
        lastClockSet = now;
        int h = ((int)beamHour) % 24;
        int m = ((int)((beamHour - (float)Math.Floor(beamHour)) * 60f)) % 60;
        Function.Call(Hash.PAUSE_CLOCK, true);
        Function.Call(Hash.SET_CLOCK_TIME, h, m, 0);
        if (!weatherSet)
        {
            weatherSet = true;
            Function.Call(Hash.CLEAR_OVERRIDE_WEATHER);
            Function.Call(Hash.SET_WEATHER_TYPE_NOW_PERSIST, "EXTRASUNNY");
        }
    }

    void OnAborted(object sender, EventArgs e)
    {
        if (camOn) { Function.Call(Hash.RENDER_SCRIPT_CAMS, false, false, 0, true, false); camOn = false; }
        Function.Call(Hash.SET_TIME_SCALE, 1f);
        Quiet(false);
        if (scriptCam != 0) { Function.Call(Hash.DESTROY_CAM, scriptCam, false); scriptCam = 0; }
        foreach (KeyValuePair<int, Proxy> kv in proxies)
            if (kv.Value.Veh != null && kv.Value.Veh.Exists()) kv.Value.Veh.Delete();
        proxies.Clear();
        DeleteDecks();
        foreach (Pole q in poles)
            if (q != null && q.E != null && q.E.Exists()) q.E.Delete();
        foreach (WObj w in wobjs.Values)
            foreach (Entity we in w.Es)
                if (we != null && we.Exists()) we.Delete();
        wobjs.Clear();
        foreach (Barrier b in barriers)
        {
            if (b == null) continue;
            if (b.E != null && b.E.Exists()) b.E.Delete();
            if (b.E2 != null && b.E2.Exists()) b.E2.Delete();
        }
        if (rx != null) rx.Close();
        if (tx != null) tx.Close();
    }

    double Now() { return clock.Elapsed.TotalSeconds; }

    void PrepareModels()
    {
        foreach (string name in ProxyModelNames)
        {
            Model m = new Model(name);
            if (!m.IsValid) continue;
            if (!m.Request(3000)) continue;
            Vector3 min, max;
            m.GetDimensions(out min, out max);
            Candidate c = new Candidate();
            c.Model = m;
            c.Size = max - min;
            c.MinZ = min.Z;
            candidates.Add(c);
        }
        Model pm = new Model(DeckPropName);
        deckIsProp = pm.IsValid && pm.Request(3000);
        if (!deckIsProp) pm = new Model(PlatformModelName);
        if (pm.IsValid && pm.Request(3000))
        {
            Vector3 min2, max2;
            pm.GetDimensions(out min2, out max2);
            platformSize = max2;
            deckMid = (min2 + max2) * 0.5f;
            deckLongX = max2.X - min2.X > max2.Y - min2.Y;
            platformWidth = Math.Max(1.5f, Math.Min(max2.X - min2.X, max2.Y - min2.Y));
            deckLen = Math.Max(max2.X - min2.X, max2.Y - min2.Y);
            deckModel = pm;
        }
        foreach (string bn in BarrierNames)
        {
            Model bm = new Model(bn);
            if (!bm.IsValid || !bm.Request(3000)) continue;
            Vector3 bmin, bmax;
            bm.GetDimensions(out bmin, out bmax);
            barrierModel = bm;
            barrierOk = true;
            barrierTop = bmax.Z;
            barrierMinZ = bmin.Z;
            barrierHeight = Math.Max(0.4f, bmax.Z - bmin.Z);
            barrierLongX = bmax.X - bmin.X > bmax.Y - bmin.Y;
            barrierHalfLen = Math.Max(bmax.X - bmin.X, bmax.Y - bmin.Y) * 0.5f;
            barrierHalfThick = Math.Min(bmax.X - bmin.X, bmax.Y - bmin.Y) * 0.5f;
            barrierCX = (bmin.X + bmax.X) * 0.5f;
            barrierCY = (bmin.Y + bmax.Y) * 0.5f;
            break;
        }
        if (barrierOk && barrierModel.Hash == new Model("sum_prop_race_barrier_01_sec").Hash)
        {
            Model bl = new Model("sum_prop_race_barrier_02_sec");
            if (bl.IsValid && bl.Request(3000))
            {
                Vector3 lmin, lmax;
                bl.GetDimensions(out lmin, out lmax);
                barrierModelL = bl;
                barrierLOk = true;
                barrierHalfLenL = Math.Max(lmax.X - lmin.X, lmax.Y - lmin.Y) * 0.5f;
                barrierCXL = (lmin.X + lmax.X) * 0.5f;
                barrierCYL = (lmin.Y + lmax.Y) * 0.5f;
            }
        }
        Model pmdl = new Model("prop_dock_woodpole4");
        if (pmdl.IsValid && pmdl.Request(3000))
        {
            Vector3 qa, qb;
            pmdl.GetDimensions(out qa, out qb);
            poleModel = pmdl;
            poleOk = true;
            poleMinZ = qa.Z;
            poleCX = (qa.X + qb.X) * 0.5f;
            poleCY = (qa.Y + qb.Y) * 0.5f;
        }
        foreach (string cn in CandNames)
        {
            int bar = cn.IndexOf(':');
            Model cm = new Model(cn.Substring(bar + 1));
            if (!cm.IsValid || !cm.Request(1500)) continue;
            Vector3 ca, cb;
            cm.GetDimensions(out ca, out cb);
            Cand cd = new Cand();
            cd.M = cm;
            cd.Kinds = int.Parse(cn.Substring(0, bar));
            cd.LongX = cb.X - ca.X >= cb.Y - ca.Y;
            cd.L = Math.Max(cb.X - ca.X, cb.Y - ca.Y);
            cd.W = Math.Min(cb.X - ca.X, cb.Y - ca.Y);
            cd.H = cb.Z - ca.Z;
            cd.CX = (ca.X + cb.X) * 0.5f;
            cd.CY = (ca.Y + cb.Y) * 0.5f;
            cd.MinZ = ca.Z;
            objCands.Add(cd);
        }
        Dbg("objects: " + objCands.Count + " stand-in props loaded");
        LoadEyes();
        modelsReady = true;
    }

    bool TryNamed(string name, out Candidate c)
    {
        if (named.TryGetValue(name, out c)) return true;
        Model m = new Model(name);
        if (!m.IsValid) { named[name] = null; return true; }
        if (!m.IsLoaded) { m.Request(); return false; }
        Vector3 min, max;
        m.GetDimensions(out min, out max);
        c = new Candidate();
        c.Model = m;
        c.Size = max - min;
        c.MinZ = min.Z;
        named[name] = c;
        return true;
    }

    Candidate PickCandidate(float width, float length, float height)
    {
        Candidate best = null;
        double bestScore = double.MaxValue;
        foreach (Candidate c in candidates)
        {
            double s = Math.Abs(Math.Log(Math.Max(width, 0.1f) / Math.Max(c.Size.X, 0.1f)))
                     + Math.Abs(Math.Log(Math.Max(length, 0.1f) / Math.Max(c.Size.Y, 0.1f)))
                     + Math.Abs(Math.Log(Math.Max(height, 0.1f) / Math.Max(c.Size.Z, 0.1f)));
            if (s < bestScore) { bestScore = s; best = c; }
        }
        return best;
    }

    static float F(string s)
    {
        float v;
        if (float.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out v)) return v;
        return 0f;
    }

    void ReceiveAll()
    {
        try
        {
            int guard = 0;
            while (rx.Available > 0 && guard++ < 128)
            {
                byte[] data = rx.Receive(ref anyEp);
                Handle(Encoding.ASCII.GetString(data));
            }
        }
        catch (Exception) { }
    }

    void Handle(string msg)
    {
        string[] f = msg.Split('|');
        if (f.Length < 2) return;
        switch (f[0])
        {
            case "C":
                if (f.Length >= 5)
                {
                    camForward = new Vector3(F(f[2]), F(f[3]), F(f[4]));
                    lastCamPacket = Now();
                }
                break;
            case "W":
                if (f.Length >= 5)
                {
                    walkerFeet = new Vector3(F(f[2]), F(f[3]), F(f[4]) + GroundLift);
                    waterZ = f.Length >= 6 ? F(f[5]) : -9999f;
                    lastWalkerPacket = Now();
                }
                break;
            case "K":
                if (f.Length >= 9)
                {
                    kPos = new Vector3(F(f[2]), F(f[3]), F(f[4]));
                    kFwd = new Vector3(F(f[5]), F(f[6]), F(f[7]));
                    kFov = F(f[8]);
                    lastK = Now();
                }
                break;
            case "L":
                if (f.Length >= 3) beamHour = F(f[2]);
                break;
            case "X":
                if (f.Length >= 2 && f[1] == "ignite") fireUntil = Now() + 6.0;
                else if (f.Length >= 5 && f[1] == "fire") { fireSpot = new Vector3(F(f[2]), F(f[3]), F(f[4])); fireSpotAt = Now(); }
                else if (f.Length >= 5 && f[1] == "boom") { boomPos = new Vector3(F(f[2]), F(f[3]), F(f[4])); boomAt = Now(); }
                break;
            case "H":
                if (f.Length >= 5) { casterWant = f[1] == "1"; casterDir = new Vector3(F(f[2]), F(f[3]), F(f[4])); casterAt = Now(); }
                break;
            case "T":
                if (f.Length >= 5) { tpTarget = new Vector3(F(f[2]), F(f[3]), F(f[4])); tpPending = true; }
                break;
            case "E":
                if (f.Length >= 2) { int.TryParse(f[1], out enterId); enterPending = true; }
                break;
            case "M":
                if (f.Length >= 3 && f[1] == "weapon") { if (!int.TryParse(f[2], out wantWeapon)) wantWeapon = -1; }
                else if (f.Length >= 3 && f[1] == "slow") wantSlow = Math.Max(0.05f, Math.Min(1f, F(f[2])));
                else if (f.Length >= 3 && f[1] == "platform") usePlatform = f[2] == "1";
                else if (f.Length >= 3 && f[1] == "ride") riding = f[2] == "1";
                else if (f.Length >= 4 && f[1] == "pace") { runPace = F(f[2]); sprintPace = F(f[3]); }
                break;
            case "J":
                {
                    int n;
                    if (f.Length >= 2 && int.TryParse(f[1], out n))
                        for (int i = 0; i < n && 2 + i * 10 + 9 < f.Length; i++)
                        {
                            int b0 = 2 + i * 10, oid, okd;
                            if (int.TryParse(f[b0], out oid) && int.TryParse(f[b0 + 1], out okd))
                                UpdateObj(oid, okd, F(f[b0 + 2]), F(f[b0 + 3]), F(f[b0 + 4]), F(f[b0 + 5]), F(f[b0 + 6]), F(f[b0 + 7]), F(f[b0 + 8]), F(f[b0 + 9]));
                        }
                }
                break;
            case "P":
                {
                    int n;
                    if (f.Length >= 2 && int.TryParse(f[1], out n))
                        for (int i = 0; i < n && 2 + i * 3 + 2 < f.Length; i++)
                            UpdatePole(F(f[2 + i * 3]), F(f[3 + i * 3]), F(f[4 + i * 3]));
                }
                break;
            case "O":
                {
                    int n;
                    if (f.Length >= 2 && int.TryParse(f[1], out n))
                        for (int i = 0; i < n && 2 + i * 7 + 6 < f.Length; i++)
                            UpdateBarrier(F(f[2 + i * 7]), F(f[3 + i * 7]), F(f[4 + i * 7]), F(f[5 + i * 7]), F(f[6 + i * 7]), F(f[7 + i * 7]), F(f[8 + i * 7]));
                }
                break;
            case "V":
                if (UseVehicleProxies && f.Length >= 15) UpdateProxy(f);
                break;
        }
    }

    void UpdateProxy(string[] f)
    {
        int id;
        if (!int.TryParse(f[1], out id)) return;
        Vector3 pos = new Vector3(F(f[2]), F(f[3]), F(f[4]) - zoff);
        Quaternion q = new Quaternion(F(f[5]), F(f[6]), F(f[7]), F(f[8]));
        float hx = F(f[9]), hy = F(f[10]), hz = F(f[11]);
        Vector3 vel = new Vector3(F(f[12]), F(f[13]), F(f[14]));

        string wantName = f.Length >= 16 ? f[15] : "";
        bool haveSeat = f.Length >= 20 && f[16] == "1";
        Vector3 drv = haveSeat ? new Vector3(F(f[17]), F(f[18]), F(f[19]) - zoff) : Vector3.Zero;

        Proxy p;
        bool have = proxies.TryGetValue(id, out p);
        if (have && p.ModelName != wantName && !entering && !riding)
        {
            if (p.Veh != null && p.Veh.Exists()) p.Veh.Delete();
            proxies.Remove(id);
            have = false;
        }
        if (!have)
        {
            Candidate c = null;
            if (wantName != "" && !TryNamed(wantName, out c)) return;
            if (c == null) c = PickCandidate(hx * 2f, hy * 2f, hz * 2f);
            if (c == null) return;
            Vehicle v = World.CreateVehicle(c.Model, pos, 0f);
            if (v == null) return;
            v.IsPersistent = true;
            v.IsInvincible = true;
            v.IsVisible = false;
            v.IsPositionFrozen = true;
            Function.Call(Hash.SET_VEHICLE_DOORS_LOCKED, v, 10);
            p = new Proxy();
            p.BeamId = id;
            p.Veh = v;
            p.MinZ = c.MinZ;
            p.Half = c.Size * 0.5f;
            p.ModelName = wantName;
            p.Created = Now();
            proxies[id] = p;
        }
        if (p.Veh == null || !p.Veh.Exists()) { proxies.Remove(id); return; }
        if (haveSeat && !p.SeatKnown && !p.Kinematic && Now() - p.Created > 0.4)
        {
            int bi = Function.Call<int>(Hash.GET_ENTITY_BONE_INDEX_BY_NAME, p.Veh, "seat_dside_f");
            if (bi >= 0)
            {
                Vector3 d = Function.Call<Vector3>(Hash.GET_WORLD_POSITION_OF_ENTITY_BONE, p.Veh, bi) - p.Veh.Position;
                p.SeatLocal = new Vector3(Vector3.Dot(d, p.Veh.RightVector), Vector3.Dot(d, p.Veh.ForwardVector), Vector3.Dot(d, p.Veh.UpVector));
                p.SeatOk = p.SeatLocal.Length() < 8f;
            }
            p.SeatKnown = true;
        }
        Vector3 target = new Vector3(pos.X, pos.Y, pos.Z - hz - p.MinZ);
        p.Veh.Quaternion = q;
        if (haveSeat)
        {
            Vector3 l;
            bool ok = eyeByModel.TryGetValue(p.ModelName, out l);
            if (!ok && p.SeatOk) { l = p.SeatLocal + DefaultEye; ok = true; }
            if (ok) target = drv - (p.Veh.RightVector * l.X + p.Veh.ForwardVector * l.Y + p.Veh.UpVector * l.Z);
        }
        bool mine = p == enterProxy && (entering || Game.Player.Character.IsInVehicle());
        Vector3 off = target - p.Veh.Position;
        float sp = vel.Length();
        if ((p.Kinematic ? sp > 0.5f : sp > 1.0f) && !mine && off.Length() < 3f)
        {
            if (!p.Kinematic)
            {
                p.Veh.IsPositionFrozen = false; p.Veh.HasGravity = false; p.Kinematic = true;
                if ((p.Veh.Position - Game.Player.Character.Position).Length() < 8f)
                    Dbg(string.Format(CultureInfo.InvariantCulture, "car {0} next to him is moving ({1:0.0} m/s): it can knock him over now", id, sp));
            }
            Vector3 pull = off * 6f;
            if (pull.Length() > 3f) pull *= 3f / pull.Length();
            p.Veh.Velocity = vel + pull;
        }
        else
        {
            if (p.Kinematic) { p.Veh.IsPositionFrozen = true; p.Kinematic = false; }
            Function.Call(Hash.SET_ENTITY_COORDS_NO_OFFSET, p.Veh, target.X, target.Y, target.Z, false, false, false);
        }
        p.Velocity = vel;
        p.LastSeen = Now();
    }

    void ExpireProxies()
    {
        double now = Now();
        foreach (KeyValuePair<int, Proxy> kv in proxies)
        {
            Proxy kp = kv.Value;
            if (kp.Kinematic && now - kp.LastSeen > 0.2 && kp.Veh != null && kp.Veh.Exists()) { kp.Veh.IsPositionFrozen = true; kp.Kinematic = false; }
        }
        if (riding) return;
        List<int> dead = null;
        foreach (KeyValuePair<int, Proxy> kv in proxies)
        {
            if (now - kv.Value.LastSeen > ProxyStaleSeconds)
            {
                if (dead == null) dead = new List<int>();
                dead.Add(kv.Key);
            }
        }
        if (dead == null) return;
        foreach (int id in dead)
        {
            Vehicle v = proxies[id].Veh;
            if (v != null && v.Exists()) v.Delete();
            proxies.Remove(id);
        }
    }

    void UpdateGround(Ped ped)
    {
        double now = Now();
        float dt = lastGroundTick < 0 ? 0f : (float)Math.Min(0.1, now - lastGroundTick);
        lastGroundTick = now;
        if (!floorSet || !pinned || now < zoffHoldUntil || entering || ped.IsInVehicle()) return;
        if (Flag(Hash.IS_PED_CLIMBING, ped) || (climbing && now - jumpAt < 0.6)) return;
        Vector3 pp = ped.Position;
        if (fallSim)
        {
            fallTarget = walkerFeet.Z - floorZ;
            fallVel = Math.Min(fallVel + 9.8f * dt, 60f);
            zoff -= fallVel * dt;
            if (zoff <= fallTarget || now - fallStart > 8.0)
            {
                if (zoff <= fallTarget) zoff = fallTarget;
                fallSim = false; fallVel = 0f;
                ragdollUntil = now + 0.8;
            }
            else
            {
                ragdollUntil = now + 0.8;
                if (!ped.IsRagdoll)
                    Function.Call(Hash.SET_PED_TO_RAGDOLL, ped, 700, 700, 0, false, false, false);
            }
            return;
        }
        float depth = waterZ - walkerFeet.Z;
        if (swimming)
        {
            if (depth < 0.9f)
            {
                float nz = walkerFeet.Z - floorZ;
                Function.Call(Hash.SET_ENTITY_COORDS_NO_OFFSET, ped, pp.X, pp.Y, Math.Max(floorZ + PedCenterHeight, pp.Z + zoff - nz), false, false, false);
                ped.Velocity = Vector3.Zero;
                zoff = nz; swimming = false; zoffJumpAt = now; groundedFrames = 0;
                Calm(false, pp);
                Dbg("out of the water");
            }
            else
            {
                float sea = SeaLevel(pp);
                zoff = waterZ - sea;
                if (now - swimDbgAt > 2.0) { swimDbgAt = now; Dbg(string.Format(CultureInfo.InvariantCulture, "swimming: GTA sea here {0:0.000} (read {1}), he is at {2:0.00}", sea, seaRead, pp.Z)); }
            }
            return;
        }
        if (depth > 1.2f && pp.Z + zoff < waterZ - 0.2f)
        {
            float nz = waterZ - SeaLevel(pp);
            Vector3 v = ped.Velocity;
            Function.Call(Hash.SET_ENTITY_COORDS_NO_OFFSET, ped, pp.X, pp.Y, pp.Z + zoff - nz, false, false, false);
            ped.Velocity = v;
            zoff = nz; swimming = true;
            Calm(true, new Vector3(pp.X, pp.Y, 0f));
            Dbg(string.Format(CultureInfo.InvariantCulture, "into the water: {0:0.0} m deep, GTA sea at {1:0.00}", depth, waterZ - nz));
            return;
        }
        float d = (walkerFeet.Z - floorZ) - zoff;
        if (Math.Abs(d) < 0.005f) return;
        float h = Math.Min(Function.Call<Vector3>(Hash.GET_PED_BONE_COORDS, ped, 0x3779, 0f, 0f, 0f).Z,
                           Function.Call<Vector3>(Hash.GET_PED_BONE_COORDS, ped, 0xCC4D, 0f, 0f, 0f).Z) - 0.1f - floorZ;
        if (d < -2.0f && !ped.IsInVehicle())
        {
            fallSim = true; fallVel = 0f; fallStart = now; fallTarget = walkerFeet.Z - floorZ;
            int ms = FallRagdollMs(-d);
            ragdollUntil = now + ms / 1000.0;
            ped.CanRagdoll = true;
            Function.Call(Hash.SET_PED_TO_RAGDOLL, ped, ms, ms, 0, false, false, false);
            Dbg(string.Format(CultureInfo.InvariantCulture, "falling {0:0.0} m", -d));
            return;
        }
        if (d < -0.45f || (h > 0.25f && Math.Abs(d) > 0.2f && d < h + 0.1f))
        {
            Vector3 v = ped.Velocity;
            Function.Call(Hash.SET_ENTITY_COORDS_NO_OFFSET, ped, pp.X, pp.Y, Math.Max(pp.Z - d, floorZ + PedCenterHeight), false, false, false);
            ped.Velocity = v;
            zoff += d; zoffJumpAt = now; groundedFrames = 0;
            Dbg(string.Format(CultureInfo.InvariantCulture, "ground {0} by {1:0.00} m: he is now {2:0.00} m above it", d < 0f ? "dropped" : "rose", Math.Abs(d), h - d));
        }
        else zoff += Math.Max(-5f * dt, Math.Min(5f * dt, d));
    }

    static int FallRagdollMs(float drop)
    {
        return (int)Math.Min(8800.0, (Math.Sqrt(2.0 * Math.Max(0f, drop) / 9.8) + 0.65) * 1000.0);
    }

    bool fallSim; float fallVel, fallTarget; double fallStart;
    bool seaRead;
    float SeaLevel(Vector3 p)
    {
        OutputArgument o = new OutputArgument();
        seaRead = Function.Call<bool>((Hash)0xF6829842C06AE524UL, p.X, p.Y, p.Z, o);
        return seaRead ? o.GetResult<float>() : 0f;
    }

    Entity MakeBarrier(float x, float y, bool large)
    {
        Model bm = large && barrierLOk ? barrierModelL : barrierModel;
        if (!bm.IsLoaded) { bm.Request(); return null; }
        Entity e = World.CreateProp(bm, new Vector3(x, y, floorZ - 30f), false, false);
        if (e == null) return null;
        e.IsPersistent = true;
        e.IsInvincible = true;
        e.IsVisible = false;
        Function.Call(Hash.SET_ENTITY_ALPHA, e.Handle, 0, false);
        e.IsPositionFrozen = true;
        return e;
    }

    static float FitAlong(float ca, float hl, float lo, float hi)
    {
        bool hasLo = lo > -900f, hasHi = hi < 900f;
        if (hasLo && hasHi && 2f * hl >= hi - lo) return (lo + hi) * 0.5f;
        if (hasHi && ca + hl > hi) ca = hi - hl;
        if (hasLo && ca - hl < lo) ca = lo + hl;
        return ca;
    }

    void SetBarrierXY(Barrier b)
    {
        b.X = b.PX + b.TX * b.CA + b.NX * barrierHalfThick;
        b.Y = b.PY + b.TY * b.CA + b.NY * barrierHalfThick;
    }

    void UpdateBarrier(float x, float y, float top, float tx, float ty, float eLo, float eHi)
    {
        if (!barrierTold)
        {
            barrierTold = true;
            Dbg(barrierOk ? string.Format(CultureInfo.InvariantCulture, "walls: barrier prop is {0:0.0} m long, {1:0.0} m high", barrierHalfLen * 2f, barrierHeight) : "walls: no barrier prop could be loaded");
        }
        if (!barrierOk || !floorSet) return;
        bool solid = top - zoff - floorZ > 5f;
        float tl = (float)Math.Sqrt(tx * tx + ty * ty);
        if (tl < 1e-4f) return;
        tx /= tl; ty /= tl;
        bool both = eLo > -900f && eHi < 900f;
        bool large = solid && barrierLOk && !(both && eHi - eLo < 2f * barrierHalfLenL - 1f);
        float hl = large ? barrierHalfLenL : barrierHalfLen;
        Barrier free = null;
        for (int i = 0; i < barriers.Length; i++)
        {
            Barrier b = barriers[i];
            if (b == null) { b = new Barrier(); barriers[i] = b; }
            if (b.Used && !b.Kill && b.Solid == solid && (solid || Math.Abs(b.Top - top) < 0.4f)
                && Math.Abs(b.TX * ty - b.TY * tx) < 0.12f
                && Math.Abs(b.TX * (y - b.PY) - b.TY * (x - b.PX)) < 0.25f
                && Math.Abs((x - b.PX) * b.TX + (y - b.PY) * b.TY - b.CA) < b.HL - 0.6f)
            {
                if (b.Large && both && eHi - eLo < 2f * b.HL - 1f) { b.Kill = true; return; }
                float ca = (b.PX + b.TX * b.CA - x) * tx + (b.PY + b.TY * b.CA - y) * ty;
                float mx = -ty, my = tx;
                if (mx * b.NX + my * b.NY < 0f) { mx = -mx; my = -my; }
                b.Seen = Now(); b.PX = x; b.PY = y; b.TX = tx; b.TY = ty;
                b.NX = mx; b.NY = my; b.Top = top;
                b.CA = FitAlong(ca, b.HL, eLo, eHi);
                b.Heading = (float)(Math.Atan2(-tx, ty) * 180.0 / Math.PI) + (barrierLongX ? 90f : 0f);
                SetBarrierXY(b); b.Fresh = true;
                return;
            }
            if (!b.Used && free == null) free = b;
        }
        if (free == null) return;
        if (free.E != null && free.E.Exists() && free.Large != large)
        {
            free.E.Delete();
            if (free.E2 != null && free.E2.Exists()) free.E2.Delete();
            free.E = null; free.E2 = null;
        }
        if (free.E == null || !free.E.Exists())
        {
            free.E = MakeBarrier(x, y, large);
            if (free.E == null) return;
        }
        float hd = (float)(Math.Atan2(-tx, ty) * 180.0 / Math.PI);
        float nx = -ty, ny = tx;
        Vector3 pp = Game.Player.Character.Position;
        if (nx * (x - pp.X) + ny * (y - pp.Y) < 0f) { nx = -nx; ny = -ny; }
        free.Used = true; free.Fresh = true; free.Kill = false; free.PX = x; free.PY = y; free.Seen = Now();
        free.NX = nx; free.NY = ny; free.Top = top;
        free.Solid = solid; free.Large = large; free.TX = tx; free.TY = ty; free.HL = hl;
        free.CA = FitAlong(0f, hl, eLo, eHi);
        SetBarrierXY(free);
        free.Heading = barrierLongX ? hd + 90f : hd;
    }

    Vector3 BarrierPos(Barrier b, float z)
    {
        double h = b.Heading * Math.PI / 180.0;
        float cx = b.Large && barrierLOk ? barrierCXL : barrierCX, cy = b.Large && barrierLOk ? barrierCYL : barrierCY;
        float c = (float)Math.Cos(h), s2 = (float)Math.Sin(h);
        return new Vector3(b.X - (cx * c - cy * s2), b.Y - (cx * s2 + cy * c), z);
    }

    void UpdateBarriers()
    {
        double now = Now();
        for (int i = 0; i < barriers.Length; i++)
        {
            Barrier b = barriers[i];
            if (b == null || !b.Used) continue;
            bool there = b.E != null && b.E.Exists();
            bool there2 = b.E2 != null && b.E2.Exists();
            if (!there || b.Kill || now - b.Seen > 1.5)
            {
                b.Used = false;
                if (there) b.E.Position = new Vector3(b.X, b.Y, floorZ - 30f);
                if (there2) b.E2.Position = new Vector3(b.X, b.Y, floorZ - 34f);
                continue;
            }
            float z = b.Solid ? floorZ + 0.5f + barrierHeight - barrierMinZ : b.Top - zoff - barrierTop;
            bool two = b.Solid || z + barrierMinZ - floorZ > 0.4f;
            if (two && !there2)
            {
                b.E2 = MakeBarrier(b.X, b.Y, b.Large);
                there2 = b.E2 != null;
                if (there2) b.Fresh = true;
            }
            if (b.Fresh || Math.Abs(z - b.Z) > 0.02f)
            {
                b.E.Position = BarrierPos(b, z);
                b.E.Heading = b.Heading;
                if (there2)
                {
                    b.E2.Position = two ? BarrierPos(b, z - barrierHeight) : new Vector3(b.X, b.Y, floorZ - 34f);
                    b.E2.Heading = b.Heading;
                }
                b.Z = z;
                b.Fresh = false;
            }
        }
    }

    void UpdatePole(float x, float y, float z)
    {
        if (!poleOk || !floorSet) return;
        Pole free = null;
        for (int i = 0; i < poles.Length; i++)
        {
            Pole q = poles[i];
            if (q == null) { q = new Pole(); poles[i] = q; }
            if (q.E != null && q.E.Exists() && (q.X - x) * (q.X - x) + (q.Y - y) * (q.Y - y) < 0.25f)
            { q.X = x; q.Y = y; q.Base = z; q.Seen = Now(); q.Active = true; return; }
            if ((q.E == null || !q.E.Exists() || !q.Active || Now() - q.Seen > 1.5) && free == null) free = q;
        }
        if (free == null) return;
        if (free.E == null || !free.E.Exists())
        {
            if (!poleModel.IsLoaded) { poleModel.Request(); return; }
            free.E = World.CreateProp(poleModel, new Vector3(x, y, floorZ - 30f), false, false);
            if (free.E == null) return;
            free.E.IsPersistent = true;
            free.E.IsInvincible = true;
            free.E.IsVisible = false;
            Function.Call(Hash.SET_ENTITY_ALPHA, free.E.Handle, 0, false);
            free.E.IsPositionFrozen = true;
        }
        free.X = x; free.Y = y; free.Base = z; free.Seen = Now(); free.Active = true;
        free.E.Heading = 0f;
        free.E.Position = new Vector3(x - poleCX, y - poleCY, free.Base - zoff - 1f - poleMinZ);
    }

    Entity PlaceCand(Cand c, float px, float py, float baseZ, float lx, float ly)
    {
        if (!c.M.IsLoaded) { c.M.Request(); return null; }
        float hd = (float)(Math.Atan2(-lx, ly) * 180.0 / Math.PI);
        if (c.LongX) hd += 90f;
        double h = hd * Math.PI / 180.0;
        float co = (float)Math.Cos(h), si = (float)Math.Sin(h);
        Entity e = World.CreateProp(c.M, new Vector3(px, py, floorZ - 30f), false, false);
        if (e == null) return null;
        e.IsPersistent = true;
        e.IsInvincible = true;
        e.IsVisible = false;
        Function.Call(Hash.SET_ENTITY_ALPHA, e.Handle, 0, false);
        e.IsPositionFrozen = true;
        e.Heading = hd;
        e.Position = new Vector3(px - (c.CX * co - c.CY * si), py - (c.CX * si + c.CY * co), baseZ - c.MinZ);
        return e;
    }

    void UpdateObj(int id, int kind, float x, float y, float z, float tx, float ty, float sx, float sy, float sz)
    {
        WObj w;
        if (wobjs.TryGetValue(id, out w))
        {
            if (w.Kind == kind && Math.Abs(w.X - x) < 0.02f && Math.Abs(w.Y - y) < 0.02f && Math.Abs(w.Z - z) < 0.02f
                && Math.Abs(w.TX - tx) < 0.002f && Math.Abs(w.TY - ty) < 0.002f
                && Math.Abs(w.SX - sx) < 0.02f && Math.Abs(w.SY - sy) < 0.02f && Math.Abs(w.SZ - sz) < 0.02f)
            { w.Seen = Now(); return; }
            foreach (Entity e in w.Es) if (e != null && e.Exists()) e.Delete();
            wobjs.Remove(id);
        }
        if (!floorSet || wobjs.Count >= 40) return;
        if (sx <= 0f || sy <= 0f || sz <= 0f) return;
        float tl = (float)Math.Sqrt(tx * tx + ty * ty);
        if (tl < 1e-4f) return;
        tx /= tl; ty /= tl;
        float lx = tx, ly = ty, L = sx, W = sy;
        if (sy > sx) { lx = -ty; ly = tx; L = sy; W = sx; }
        int mask = 1 << kind;
        Cand best = null; float bestScore = float.MaxValue; int bestN = 1;
        for (int pass = 0; pass < 2 && best == null; pass++)
            foreach (Cand c in objCands)
            {
                if ((c.Kinds & (pass == 0 ? mask : 32)) == 0) continue;
                if (kind == 5 && (c.L <= 0.1f || c.W <= 0.1f || c.H <= 0.1f
                    || TileCount(L, c.L) * TileCount(W, c.W) * TileCount(sz, c.H) > 24)) continue;
                int n = 1; float score;
                if (kind == 2)
                {
                    n = Math.Max(1, Math.Min(8, (int)Math.Round(L / Math.Max(0.5f, c.L))));
                    score = Math.Abs(n * c.L - L);
                }
                else score = Math.Abs(c.L - L) + Math.Abs(c.W - W) + Math.Abs(c.H - sz)
                    + 4f * (Math.Max(0f, c.L - L) + Math.Max(0f, c.W - W) + Math.Max(0f, c.H - sz));
                if (score < bestScore) { bestScore = score; best = c; bestN = n; }
            }
        if (best == null) return;
        w = new WObj();
        w.Seen = Now();
        w.X = x; w.Y = y; w.Z = z; w.TX = tx; w.TY = ty; w.SX = sx; w.SY = sy; w.SZ = sz; w.Kind = kind; w.ZOff = zoff;
        float baseZ = z - zoff;
        int cols = kind == 5 ? TileCount(L, best.L) : bestN;
        int rows = kind == 5 ? TileCount(W, best.W) : 1;
        int layers = kind == 5 ? TileCount(sz, best.H) : 1;
        for (int i = 0; i < cols; i++)
        {
            float off = kind == 5 ? TileOffset(L, best.L, i, cols) : (i + 0.5f) * best.L - bestN * best.L * 0.5f;
            for (int r = 0; r < rows; r++)
            {
                float side = kind == 5 ? TileOffset(W, best.W, r, rows) : 0f;
                for (int j = 0; j < layers; j++)
                {
                    float dz = kind == 5 ? (layers == 1 ? sz - best.H : (sz - best.H) * j / (layers - 1)) : 0f;
                    Entity e = PlaceCand(best, x + lx * off - ly * side, y + ly * off + lx * side, baseZ + dz, lx, ly);
                    if (e != null) w.Es.Add(e);
                }
            }
        }
        if (w.Es.Count > 0) wobjs[id] = w;
    }

    static int TileCount(float length, float size)
    {
        return Math.Max(1, (int)Math.Ceiling(length / Math.Max(0.1f, size)));
    }

    static float TileOffset(float length, float size, int index, int count)
    {
        return count <= 1 ? 0f : (length - size) * (index / (float)(count - 1) - 0.5f);
    }

    void UpdateObjs()
    {
        double now = Now();
        List<int> gone = null;
        foreach (KeyValuePair<int, WObj> kv in wobjs)
        {
            if (now - kv.Value.Seen > 3.0)
            {
                foreach (Entity e in kv.Value.Es) if (e != null && e.Exists()) e.Delete();
                if (gone == null) gone = new List<int>();
                gone.Add(kv.Key);
            }
            else
            {
                WObj w = kv.Value;
                float dz = w.ZOff - zoff;
                if (Math.Abs(dz) > 0.0001f)
                {
                    foreach (Entity e in w.Es) if (e != null && e.Exists()) e.Position += new Vector3(0f, 0f, dz);
                    w.ZOff = zoff;
                }
            }
        }
        if (gone != null) foreach (int k in gone) wobjs.Remove(k);
    }

    void UpdatePoles()
    {
        double now = Now();
        for (int i = 0; i < poles.Length; i++)
        {
            Pole q = poles[i];
            if (q == null || q.E == null || !q.E.Exists()) continue;
            q.Active = now - q.Seen <= 1.5;
            Vector3 pos = q.Active ? new Vector3(q.X - poleCX, q.Y - poleCY, q.Base - zoff - 1f - poleMinZ) : new Vector3(q.X, q.Y, floorZ - 30f);
            if ((q.E.Position - pos).Length() > 0.002f) q.E.Position = pos;
        }
    }

    bool NearBarrier(Ped ped, bool climbable)
    {
        Vector3 pp = ped.Position;
        for (int i = 0; i < barriers.Length; i++)
        {
            Barrier b = barriers[i];
            if (b == null || !b.Used || (climbable && b.Solid)) continue;
            float dx = pp.X - b.X, dy = pp.Y - b.Y;
            if (dx * dx + dy * dy < (b.HL + 1.0f) * (b.HL + 1.0f)) return true;
        }
        return false;
    }

    bool NearWorldObj(Ped ped)
    {
        Vector3 pp = ped.Position, forward = ped.ForwardVector;
        float feet = Math.Min(Function.Call<Vector3>(Hash.GET_PED_BONE_COORDS, ped, 0x3779, 0f, 0f, 0f).Z,
                              Function.Call<Vector3>(Hash.GET_PED_BONE_COORDS, ped, 0xCC4D, 0f, 0f, 0f).Z) - 0.1f;
        foreach (WObj w in wobjs.Values)
        {
            if (Now() - w.Seen > 0.75) continue;
            float rise = w.Z + w.SZ - zoff - feet;
            if (rise < 0.25f || rise > 2.5f) continue;
            float u = (pp.X - w.X) * w.TX + (pp.Y - w.Y) * w.TY;
            float v = -(pp.X - w.X) * w.TY + (pp.Y - w.Y) * w.TX;
            float cu = Math.Max(-w.SX * 0.5f, Math.Min(w.SX * 0.5f, u));
            float cv = Math.Max(-w.SY * 0.5f, Math.Min(w.SY * 0.5f, v));
            float dx = w.X + w.TX * cu - w.TY * cv - pp.X;
            float dy = w.Y + w.TY * cu + w.TX * cv - pp.Y;
            float d2 = dx * dx + dy * dy;
            if (d2 < 1.44f && (d2 < 0.04f || dx * forward.X + dy * forward.Y > 0.25f * Math.Sqrt(d2))) return true;
        }
        return false;
    }

    bool orphansCleaned;
    void UpdatePlatform(Ped ped)
    {
        if (!usePlatform || Now() - lastWalkerPacket > 5.0) { DeleteDecks(); return; }
        if (!pinned || ped.IsInVehicle()) return;
        if (!orphansCleaned && deckModel.IsValid)
        {
            orphansCleaned = true;
            foreach (Prop o in World.GetNearbyProps(new Vector3(5000f, 5000f, 60f), 300f, deckModel))
                if (o.IsVisible) o.Delete();
        }
        float cw = (deckLongX ? deckLen : platformWidth) * 0.98f, ch = (deckLongX ? platformWidth : deckLen) * 0.98f;
        int nx = deckLongX ? DeckRows : DeckCols, ny = deckLongX ? DeckCols : DeckRows;
        Vector3 pp = ped.Position;
        int cx = (int)Math.Floor(pp.X / cw), cy = (int)Math.Floor(pp.Y / ch);
        deckZ = floorZ - platformSize.Z + platCal;
        bool all = true;
        for (int i = 0; i < nx; i++)
        {
            for (int j = 0; j < ny; j++)
            {
                int sx = cx - nx / 2 + i, sy = cy - ny / 2 + j;
                int k = ((sx % nx + nx) % nx) * ny + (sy % ny + ny) % ny;
                Vector3 t = new Vector3((sx + 0.5f) * cw - deckMid.X, (sy + 0.5f) * ch - deckMid.Y, deckZ);
                Entity d = decks[k];
                if (d == null || !d.Exists())
                {
                    d = MakeDeck(t);
                    decks[k] = d;
                    deckPos[k] = new Vector3(0f, 0f, -9999f);
                    if (d == null) { all = false; continue; }
                }
                if ((t - deckPos[k]).Length() > 0.002f) { d.Position = t; d.Heading = 0f; deckPos[k] = t; }
            }
        }
        decksReady = all;
    }

    void DeleteDecks()
    {
        for (int i = 0; i < decks.Length; i++)
        {
            if (decks[i] != null && decks[i].Exists()) decks[i].Delete();
            decks[i] = null;
        }
        decksReady = false;
    }

    Entity MakeDeck(Vector3 at)
    {
        if (!deckModel.IsValid) return null;
        if (!deckModel.IsLoaded) { deckModel.Request(); Dbg("deck model not loaded"); return null; }
        at.Z -= 20f;
        Entity e;
        if (deckIsProp) e = World.CreateProp(deckModel, at, false, false);
        else e = World.CreateVehicle(deckModel, at, 0f);
        if (e == null) return null;
        e.IsPersistent = true;
        e.IsInvincible = true;
        e.IsVisible = false;
        Function.Call(Hash.SET_ENTITY_ALPHA, e.Handle, 0, false);
        e.IsPositionFrozen = true;
        if (deckIsProp) Function.Call(Hash.SET_ENTITY_DYNAMIC, e, false);
        if (!deckIsProp) Function.Call(Hash.SET_VEHICLE_DOORS_LOCKED, e.Handle, 10);
        return e;
    }

    static bool Down(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }

    uint ownPid = (uint)Process.GetCurrentProcess().Id;
    bool BeamNgFocused()
    {
        double now = Now();
        if (now - lastFocusCheck < 0.25) return beamFocused;
        lastFocusCheck = now;
        uint pid = 0;
        try { GetWindowThreadProcessId(GetForegroundWindow(), out pid); } catch (Exception) { }
        beamFocused = pid != 0 && pid != ownPid;
        return beamFocused;
    }

    static void SetControl(Control c, float v)
    {
        Function.Call(Hash.SET_CONTROL_VALUE_NEXT_FRAME, 0, (int)c, v);
    }

    const string EyeFile = "scripts\\BeamBridge.eyes2.txt";
    void LoadEyes()
    {
        try
        {
            if (!System.IO.File.Exists(EyeFile)) return;
            foreach (string line in System.IO.File.ReadAllLines(EyeFile))
            {
                string[] a = line.Split('|');
                if (a.Length >= 4) eyeByModel[a[0]] = new Vector3(F(a[1]), F(a[2]), F(a[3]));
            }
        }
        catch (Exception) { }
    }
    void SaveEyes()
    {
        try
        {
            CultureInfo ci = CultureInfo.InvariantCulture;
            StringBuilder sb = new StringBuilder();
            foreach (KeyValuePair<string, Vector3> kv in eyeByModel)
                sb.Append(kv.Key).Append('|').Append(kv.Value.X.ToString("F3", ci)).Append('|').Append(kv.Value.Y.ToString("F3", ci)).Append('|').Append(kv.Value.Z.ToString("F3", ci)).Append("\r\n");
            System.IO.File.WriteAllText(EyeFile, sb.ToString());
        }
        catch (Exception) { }
    }

    void UpdateEnter(Ped ped)
    {
        if (enterPending)
        {
            enterPending = false;
            Proxy p;
            if (enterId != 0 && proxies.TryGetValue(enterId, out p) && p.Veh != null && p.Veh.Exists())
            {
                Function.Call(Hash.SET_VEHICLE_DOORS_LOCKED, p.Veh, 1);
                Function.Call((Hash)0xC20E50AA46D09CA8UL, ped, p.Veh, 12000, -1, 1.0f, 1, 0);
                enterVeh = p.Veh;
                enterProxy = p;
                seatedAt = -999;
                enterAt = Now();
                entering = true;
                tasked = false;
            }
            else
            {
                if (entering) Function.Call(Hash.CLEAR_PED_TASKS, ped);
                entering = false;
            }
        }
        if (ped.IsInVehicle() && enterProxy != null && enterProxy.Veh != null && enterProxy.Veh.Exists())
        {
            if (seatedAt < 0) seatedAt = Now();
            if (Now() - seatedAt > 3.0 && !eyeByModel.ContainsKey(enterProxy.ModelName))
            {
                Vehicle ev = enterProxy.Veh;
                Vector3 d = Function.Call<Vector3>(Hash.GET_PED_BONE_COORDS, ped, 0x796E, 0f, 0f, 0f) - ev.Position;
                Vector3 e = new Vector3(Vector3.Dot(d, ev.RightVector), Vector3.Dot(d, ev.ForwardVector), Vector3.Dot(d, ev.UpVector) + 0.10f);
                if (e.Length() < 6f) { eyeByModel[enterProxy.ModelName] = e; SaveEyes(); }
            }
        }
        if (!entering) return;
        if (ped.IsInVehicle()) { entering = false; return; }
        bool moveKey = BeamNgFocused() && (Down(VK_W) || Down(VK_A) || Down(VK_S) || Down(VK_D));
        if ((moveKey && Now() - enterAt > 0.4) || Now() - enterAt > 12.0)
        {
            Function.Call(Hash.CLEAR_PED_TASKS, ped);
            entering = false;
        }
    }

    void InjectInput(Ped ped)
    {
        bool foc = BeamNgFocused();
        if (ShowDebug && Now() - lastDbg > 1.0)
        {
            lastDbg = Now();
            GTA.UI.Screen.ShowSubtitle(string.Format("BeamBridge focus={0} cam={1:0.0}s W={2} walker={3} rag={4} air={5} z={6:0.00}/{7:0.00} plat={8}", foc, Now() - lastCamPacket, Down(VK_W), pinned, ped.IsRagdoll, ped.IsInAir, ped.Position.Z, walkerFeet.Z + PedCenterHeight,decksReady ? (deckIsProp ? "prop " : "trailer ") + deckZ.ToString("0.00") : "none"), 1100);
        }
        if (!foc) return;
        if (lastCamPacket < 0) return;
        if (riding || entering || ped.IsInVehicle())
        {
            if (tasked) { Function.Call(Hash.CLEAR_PED_TASKS, ped); tasked = false; }
            return;
        }

        float fx = camForward.X, fy = camForward.Y, fz = Math.Max(-1f, Math.Min(1f, camForward.Z));
        double camHeading = Math.Atan2(-fx, fy) * 180.0 / Math.PI;
        double rel = camHeading - ped.Heading;
        while (rel > 180.0) rel -= 360.0;
        while (rel < -180.0) rel += 360.0;
        float pitch = (float)(Math.Asin(fz) * 180.0 / Math.PI);
        Function.Call(Hash.SET_GAMEPLAY_CAM_RELATIVE_HEADING, (float)(rel * CameraHeadingSign));
        Function.Call(Hash.SET_GAMEPLAY_CAM_RELATIVE_PITCH, pitch, 1.0f);

        float mx = (Down(VK_D) ? 1f : 0f) - (Down(VK_A) ? 1f : 0f);
        float my = (Down(VK_S) ? 1f : 0f) - (Down(VK_W) ? 1f : 0f);
        if (mx != 0f) SetControl(Control.MoveLeftRight, mx);
        if (my != 0f) SetControl(Control.MoveUpDown, my);
        bool sp = Down(VK_SPACE);
        if (!Function.Call<bool>(Hash.HAS_ANIM_DICT_LOADED, RollDict)) Function.Call(Hash.REQUEST_ANIM_DICT, RollDict);
        if (sp && !spaceWas && gunMode != 0 && !swimming && !ped.IsInAir && !ped.IsRagdoll && Now() > rollUntil)
        {
            StartRoll(ped, mx, my);
        }
        else if (sp && !spaceWas && !swimming && !ped.IsInAir && !ped.IsRagdoll && Now() - jumpAt > 0.7 && Now() > rollUntil)
        {
            climbing = NearWorldObj(ped) || NearProxy(ped) || NearBarrier(ped, true);
            if (climbing) Function.Call((Hash)0x89D9FCC2435112F1UL, ped, true);
            else Function.Call((Hash)0x0AE4086104E067B1UL, ped, true, false, false);
            jumpAt = Now();
            tasked = false;
        }
        spaceWas = sp;
        bool jumping = Now() - jumpAt < (climbing ? 2.2 : 0.4) || Flag(Hash.IS_PED_JUMPING, ped) || Flag(Hash.IS_PED_CLIMBING, ped) || Now() < rollUntil;
        if (rollNext != null && Now() >= rollNextAt)
        {
            Function.Call(Hash.TASK_PLAY_ANIM, ped, RollDict, rollNext, 8f, -8f, -1, 0, 0f, false, false, false);
            rollNext = null;
        }
        if (rollClip != null && Now() > rollCheckAt)
        {
            if (!Function.Call<bool>(Hash.IS_ENTITY_PLAYING_ANIM, ped, RollDict, rollClip, 3)) { Dbg("combat roll: GTA is not playing " + rollClip); rollUntil = Now(); rollNext = null; }
            rollClip = null;
        }
        bool tab = Down(VK_TAB);
        if (tab && !tabWas) { tabAt = Now(); wheelCentred = false; }
        if (tab && !wheelCentred && Now() - tabAt > 0.35) wheelCentred = CentreWheelPointer();
        tabWas = tab;
        if (wantWeapon >= 0)
        {
            if (wantWeapon < Loadout.Length && !swimming)
            {
                weaponIdx = wantWeapon;
                Function.Call(Hash.SET_CURRENT_PED_WEAPON, ped, Function.Call<int>(Hash.GET_HASH_KEY, Loadout[weaponIdx]), true);
            }
            wantWeapon = -1;
        }
        if (GunTasks(ped, mx, my, camHeading, jumping)) { }
        else if ((mx != 0f || my != 0f) && !ped.IsRagdoll && !ped.IsInVehicle() && !jumping)
        {
            double h = camHeading * Math.PI / 180.0;
            double fwdX = -Math.Sin(h), fwdY = Math.Cos(h);
            double rgtX = Math.Cos(h), rgtY = Math.Sin(h);
            double dx = fwdX * -my + rgtX * mx, dy = fwdY * -my + rgtY * mx;
            double len = Math.Sqrt(dx * dx + dy * dy); dx /= len; dy /= len;
            Vector3 p = ped.Position;
            float spd = Down(VK_LSHIFT) ? sprintPace : runPace;
            Function.Call(Hash.TASK_GO_STRAIGHT_TO_COORD, ped, p.X + (float)dx * 6f, p.Y + (float)dy * 6f, p.Z, spd, 150, (float)(Math.Atan2(-dx, dy) * 180.0 / Math.PI), 0.0f);
            tasked = true;
        }
        else if (tasked && !jumping) { Function.Call(Hash.CLEAR_PED_TASKS, ped); tasked = false; }
        if (Down(VK_LSHIFT)) SetControl(Control.Sprint, 1f);
        if (Down(VK_LCONTROL)) SetControl(Control.Duck, 1f);
        if (Down(VK_R)) SetControl(Control.Reload, 1f);
        bool qd = Down(VK_Q);
        if (qd && !qWas) PlaceCover(ped);
        qWas = qd;
        if (qd) SetControl(Control.Cover, 1f);
        if (Down(VK_G)) SetControl(Control.Enter, 1f);
        if (Down(VK_E)) SetControl(Control.Context, 1f);
        if (Down(VK_LBUTTON)) SetControl(Control.Attack, 1f);
        if (Down(VK_RBUTTON)) SetControl(Control.Aim, 1f);
    }

    bool qWas;
    void PlaceCover(Ped ped)
    {
        Vector3 pp = ped.Position;
        Barrier best = null;
        float bd = 6.25f;
        for (int i = 0; i < barriers.Length; i++)
        {
            Barrier b = barriers[i];
            if (b == null || !b.Used) continue;
            float dx = pp.X - b.PX, dy = pp.Y - b.PY, d2 = dx * dx + dy * dy;
            if (d2 < bd) { bd = d2; best = b; }
        }
        if (best == null) return;
        double h = (best.Heading - (barrierLongX ? 90f : 0f)) * Math.PI / 180.0;
        double nx = Math.Cos(h), ny = Math.Sin(h);
        double side = (pp.X - best.PX) * nx + (pp.Y - best.PY) * ny >= 0 ? 1.0 : -1.0;
        double ox = nx * side, oy = ny * side;
        float cx = best.PX + (float)ox * 0.35f, cy = best.PY + (float)oy * 0.35f;
        float face = (float)(Math.Atan2(-ox, oy) * 180.0 / Math.PI);
        Function.Call(Hash.ADD_COVER_POINT, cx, cy, pp.Z - 1.0f, face, 2, 1, 0, true);
        Dbg(string.Format(CultureInfo.InvariantCulture, "cover point at {0:0.0},{1:0.0} facing {2:0}", cx, cy, face));
    }

    static bool Flag(Hash h, Ped p) { return Function.Call<bool>(h, p); }

    double dbgAt = -999;
    void Dbg(string s)
    {
        if (Now() - dbgAt < 0.25) return;
        dbgAt = Now();
        try { byte[] b = Encoding.ASCII.GetBytes("D|" + s); tx.Send(b, b.Length, "127.0.0.1", BeamPort); } catch (Exception) { }
    }

    int muzzleLogged;
    void MuzzleLog(int w, string how, Vector3 p, Vector3 mn, Vector3 mx)
    {
        if (muzzleLogged == w) return;
        muzzleLogged = w;
        try
        {
            System.IO.File.AppendAllText("scripts\\BeamBridge.muzzle.log", string.Format(CultureInfo.InvariantCulture, "{0:HH:mm:ss} weapon {1} via {2} at {3:0.00},{4:0.00},{5:0.00} dims {6:0.00},{7:0.00},{8:0.00} to {9:0.00},{10:0.00},{11:0.00}\r\n", DateTime.Now, w, how, p.X, p.Y, p.Z, mn.X, mn.Y, mn.Z, mx.X, mx.Y, mx.Z));
        }
        catch { }
    }

    static readonly float[] BarrelLen = { 0f, 0.22f, 0.42f, 0.68f, 0.72f };

    Vector3 muzDir;
    Vector3 Muzzle(Ped ped)
    {
        muzDir = Vector3.Zero;
        if (weaponIdx <= 0) return Vector3.Zero;
        int w = Function.Call<int>((Hash)0x3B390A939AF0B5FCUL, ped, 0);
        if (w != 0)
        {
            Vector3 origin = Function.Call<Vector3>(Hash.GET_ENTITY_COORDS, w, true);
            Vector3 fwd = Function.Call<Vector3>(Hash.GET_ENTITY_FORWARD_VECTOR, w);
            if (fwd.Length() > 0.01f) fwd.Normalize();
            string[] names = { "gun_vfx_muzzle", "gun_vfx", "gun_muzzle", "gun_barrels" };
            foreach (string n in names)
            {
                int bi = Function.Call<int>(Hash.GET_ENTITY_BONE_INDEX_BY_NAME, w, n);
                if (bi != -1)
                {
                    Vector3 bp = Function.Call<Vector3>(Hash.GET_WORLD_POSITION_OF_ENTITY_BONE, w, bi);
                    Vector3 g = bp - origin;
                    if (g.Length() > 0.03f) g.Normalize(); else g = fwd;
                    muzDir = Vector3.Dot(fwd, g) > 0.8f ? fwd : g;
                    MuzzleLog(w, n, bp, origin, muzDir);
                    return bp;
                }
            }
            muzDir = fwd;
            Vector3 tip = origin + fwd * BarrelLen[Math.Min(weaponIdx, BarrelLen.Length - 1)];
            MuzzleLog(w, "entity forward", tip, origin, fwd);
            return tip;
        }
        if (aimMarker == null || !aimMarker.Exists() || gunMode == 0) return Vector3.Zero;
        Vector3 hand = Function.Call<Vector3>(Hash.GET_PED_BONE_COORDS, ped, 0x49D9, 0f, 0f, 0f);
        Vector3 dir = aimMarker.Position - hand;
        if (dir.Length() < 0.1f) return Vector3.Zero;
        dir.Normalize();
        muzDir = dir;
        Vector3 mz = hand + dir * BarrelLen[Math.Min(weaponIdx, BarrelLen.Length - 1)];
        MuzzleLog(w, "hand and aim", mz, Vector3.Zero, Vector3.Zero);
        return mz;
    }

    void SendState(Ped ped)
    {
        int flags = 0;
        if (Flag(Hash.IS_PED_RAGDOLL, ped)) flags |= 1;
        if (Flag(Hash.IS_PED_SPRINTING, ped)) flags |= 2;
        if (Flag(Hash.IS_PED_RUNNING, ped)) flags |= 4;
        if (Flag(Hash.IS_PED_WALKING, ped)) flags |= 8;
        if (Flag(Hash.IS_PED_JUMPING, ped)) flags |= 16;
        if (Flag(Hash.IS_PED_FALLING, ped)) flags |= 32;
        if (Flag(Hash.IS_PED_CLIMBING, ped)) flags |= 64;
        if (Function.Call<bool>(Hash.IS_PLAYER_FREE_AIMING, Game.Player.Handle)) flags |= 128;
        if (Flag(Hash.IS_PED_SHOOTING, ped))
        {
            flags |= 256;
            if (Now() - shotAt > 0.06) { shots++; shotAt = Now(); }
        }
        if (Down(VK_TAB) && BeamNgFocused()) flags |= 524288;
        if (Flag(Hash.IS_PED_RELOADING, ped)) flags |= 512;
        if (Function.Call<bool>(Hash.IS_PED_IN_COVER, ped, false)) flags |= 1024;
        if (ped.IsInVehicle()) flags |= 2048;
        if (ped.IsDead) flags |= 4096;
        if (Flag(Hash.IS_PED_DUCKING, ped)) flags |= 8192;
        if (enterVeh != null && enterVeh.Exists() && (entering || ped.IsInVehicle()))
        {
            for (int door = 0; door < 4; door++)
                if (Function.Call<float>((Hash)0xFE3F9C29F7B32BD5UL, enterVeh, door) > 0.1f) { flags |= 16384 | (door * 131072); break; }
        }
        if (entering) flags |= 32768;
        if (swimming) flags |= 65536;

        int weapon = 0;
        try { weapon = (int)ped.Weapons.Current.Hash; } catch (Exception) { }

        Vector3 pos = ped.Position;
        Vector3 vel = ped.Velocity;
        CultureInfo ci = CultureInfo.InvariantCulture;
        StringBuilder sb = new StringBuilder(512);
        sb.Append("P|").Append(++seq).Append('|')
          .Append(pos.X.ToString("F3", ci)).Append('|').Append(pos.Y.ToString("F3", ci)).Append('|').Append((pos.Z + zoff).ToString("F3", ci)).Append('|')
          .Append(ped.Heading.ToString("F2", ci)).Append('|')
          .Append(vel.X.ToString("F2", ci)).Append('|').Append(vel.Y.ToString("F2", ci)).Append('|').Append(vel.Z.ToString("F2", ci)).Append('|')
          .Append(flags).Append('|').Append(weapon).Append('|').Append(ped.Health).Append('|');

        for (int i = 0; i < BoneIds.Length; i++)
        {
            Vector3 b = Function.Call<Vector3>(Hash.GET_PED_BONE_COORDS, ped, BoneIds[i], 0f, 0f, 0f);
            if (i > 0) sb.Append(',');
            sb.Append(b.X.ToString("F3", ci)).Append(',').Append(b.Y.ToString("F3", ci)).Append(',').Append((b.Z + zoff).ToString("F3", ci));
        }
        sb.Append('|').Append(Now().ToString("F4", ci));
        sb.Append('|').Append(shots);
        Vector3 mz = Muzzle(ped);
        sb.Append('|');
        if (mz.Length() > 0.001f) sb.Append(mz.X.ToString("F3", ci)).Append(',').Append(mz.Y.ToString("F3", ci)).Append(',').Append((mz.Z + zoff).ToString("F3", ci)).Append(',').Append(muzDir.X.ToString("F4", ci)).Append(',').Append(muzDir.Y.ToString("F4", ci)).Append(',').Append(muzDir.Z.ToString("F4", ci));

        try
        {
            byte[] bytes = Encoding.ASCII.GetBytes(sb.ToString());
            tx.Send(bytes, bytes.Length, "127.0.0.1", BeamPort);
        }
        catch (Exception) { }
    }

    static Vector3 LocalTo(Vehicle v, Vector3 world)
    {
        Vector3 d = world - v.Position;
        return new Vector3(Vector3.Dot(d, v.RightVector), Vector3.Dot(d, v.ForwardVector), Vector3.Dot(d, v.UpVector));
    }

    bool OnProxy(Ped ped, float tz)
    {
        if (ped.Position.Z < tz + 0.3f) return false;
        foreach (KeyValuePair<int, Proxy> kv in proxies)
        {
            Proxy p = kv.Value;
            if (p.Veh == null || !p.Veh.Exists()) continue;
            Vector3 l = LocalTo(p.Veh, ped.Position);
            if (Math.Abs(l.X) < p.Half.X + 0.3f && Math.Abs(l.Y) < p.Half.Y + 0.3f) return true;
        }
        return false;
    }

    bool NearProxy(Ped ped)
    {
        foreach (KeyValuePair<int, Proxy> kv in proxies)
        {
            Proxy p = kv.Value;
            if (p.Veh == null || !p.Veh.Exists()) continue;
            Vector3 l = LocalTo(p.Veh, ped.Position);
            if (Math.Abs(l.X) < p.Half.X + 1.6f && Math.Abs(l.Y) < p.Half.Y + 1.6f) return true;
        }
        return false;
    }

    void MovingProxies()
    {
        foreach (KeyValuePair<int, Proxy> kv in proxies)
        {
            Proxy p = kv.Value;
            if (!p.Kinematic || p.Veh == null || !p.Veh.Exists()) continue;
            foreach (Entity sv in decks)
                if (sv != null && sv.Exists()) Function.Call(Hash.SET_ENTITY_NO_COLLISION_ENTITY, p.Veh, sv.Handle, true);
        }
    }

    bool MovingProxyNear(Ped ped)
    {
        foreach (KeyValuePair<int, Proxy> kv in proxies)
        {
            Proxy p = kv.Value;
            if (!p.Kinematic || p.Veh == null || !p.Veh.Exists()) continue;
            Vector3 l = LocalTo(p.Veh, ped.Position);
            if (Math.Abs(l.X) < p.Half.X + 3f && Math.Abs(l.Y) < p.Half.Y + 3f) return true;
        }
        return false;
    }
}
