local M = {}
local logTag = "gtaBridge"

local socket = require("socket.socket")

local cfgPath = "/settings/gtaBridge.json"
local cfg = {
  host = "127.0.0.1",
  gtaPort = 47200,
  listenPort = 47201,
  yawDeg = 0,
  sunTrim = -24,
  ox = 0, oy = 0, oz = 0,
  anchorX = 5000, anchorY = 5000, anchorZ = 60,
  compose = true,
  fovMul = 1.0,
  syncTime = true,
  swim = true,
  walls = true,
  bodySpeed = 2.0,
  bodyNear = 15,
  bodyCollide = true,
cars = true,
  carRadius = 40,
  carMax = 6,
enterAnim = true,
  headTop = 0.17,
  doorPush = 80,
  doorPushTime = 0.4,
  doorHold = 30,
  wheelSlowMo = 0.2,
  wheelGhost = 0.3,
  bullets = true,
  bulletRange = 300,
  bulletPush = 6,
  bulletHoles = 80,
  holeSize = 0.018,
  tracer = 0.12,
  wheelHold = 0.18,
  busDoorForce = 150,
  doorPull = 130,
  doorPullTime = 0.35,
  runPace = 1.5,
  sprintPace = 2.5,
  sunFlip = false,
  predict = true,
  predictGain = 0.8,
  autoEngage = true,
  usePuppet = true,
  renderBody = true,
  flipQuat = false,
  sendVehicles = false,
  vehicleRadius = 120,
  vehicleHz = 30,
  maxVehicles = 40,
  drawSkeleton = false,
  usePlatform = true,
  staleTimeout = 1.5,
  thirdPerson = true,
  camDist = 3.2,
  camShoulder = 0.45,
  camHeight = 0.2,
  camPivotRate = 12,
  camPushOut = 3,
}

local S = { lastVehSend = 0, restDumped = false, bodyHoldT = 0, offsetAt = 0, lastGroundFloor = -500, dbgT = 0, sunLogT = 0, lastTimeSend = 0, toggleT = 0, obsT = 0, bodyWantT = 0, tabT = 0, lastGun = 1, rideMsgT = 0, paceT = 0 }
local udp
local running = false
local engaged = false
local yawRad = 0
local seq = 0
local ped = { fresh = false, t = 0 }
local slow = 1
local stat = { frames = 0, pkts = 0, t = 0, puppetN = 0, puppetT = 0, puppetRate = 0 }
local walkerId

local function applyConfig()
  yawRad = math.rad(cfg.yawDeg + cfg.sunTrim)
end

local function loadConfig()
  local ok, data = pcall(jsonReadFile, cfgPath)
  if ok and type(data) == "table" then
    for k, v in pairs(data) do
      if cfg[k] ~= nil and k ~= "sunTrim" and k ~= "anchorX" and k ~= "anchorY" and k ~= "anchorZ" and k ~= "drawSkeleton" and k ~= "compose" then cfg[k] = v end
    end
  end
  applyConfig()
end

local function saveConfig()
  pcall(jsonWriteFile, cfgPath, cfg, true)
end

local function rotZ(x, y, a)
  local c, s = math.cos(a), math.sin(a)
  return c * x - s * y, s * x + c * y
end

local function gtaToBeam(x, y, z)
  local rx, ry = rotZ(x, y, yawRad)
  return rx + cfg.ox, ry + cfg.oy, z + cfg.oz
end

local function beamToGta(x, y, z)
  local rx, ry = rotZ(x - cfg.ox, y - cfg.oy, -yawRad)
  return rx, ry, z - cfg.oz
end

local function dirToBeam(x, y, z)
  local rx, ry = rotZ(x, y, yawRad)
  return rx, ry, z
end

local function dirToGta(x, y, z)
  local rx, ry = rotZ(x, y, -yawRad)
  return rx, ry, z
end

local function split(s, sep)
  local out, n, start = {}, 0, 1
  while true do
    local i = string.find(s, sep, start, true)
    n = n + 1
    if not i then
      out[n] = string.sub(s, start)
      break
    end
    out[n] = string.sub(s, start, i - 1)
    start = i + 1
  end
  return out
end

local function send(str)
  if not udp then return end
  pcall(udp.sendto, udp, str, cfg.host, cfg.gtaPort)
end

local function quatFromBasis(rx, ry, rz, fx, fy, fz, ux, uy, uz)
  local m00, m01, m02 = rx, fx, ux
  local m10, m11, m12 = ry, fy, uy
  local m20, m21, m22 = rz, fz, uz
  local tr = m00 + m11 + m22
  local x, y, z, w
  if tr > 0 then
    local s = math.sqrt(tr + 1) * 2
    w = 0.25 * s; x = (m21 - m12) / s; y = (m02 - m20) / s; z = (m10 - m01) / s
  elseif m00 > m11 and m00 > m22 then
    local s = math.sqrt(1 + m00 - m11 - m22) * 2
    w = (m21 - m12) / s; x = 0.25 * s; y = (m01 + m10) / s; z = (m02 + m20) / s
  elseif m11 > m22 then
    local s = math.sqrt(1 + m11 - m00 - m22) * 2
    w = (m02 - m20) / s; x = (m01 + m10) / s; y = 0.25 * s; z = (m12 + m21) / s
  else
    local s = math.sqrt(1 + m22 - m00 - m11) * 2
    w = (m10 - m01) / s; x = (m02 + m20) / s; y = (m12 + m21) / s; z = 0.25 * s
  end
  return x, y, z, w
end

local bones = {
  {1, 2}, {2, 3}, {3, 4},
  {3, 5}, {5, 6}, {6, 7}, {7, 8},
  {3, 9}, {9, 10}, {10, 11}, {11, 12},
  {1, 13}, {13, 14}, {14, 15},
  {1, 16}, {16, 17}, {17, 18},
}

local skHist = {}
local clk = {}
local function packetAge(now, gt)
  clk[#clk + 1] = now - gt
  if #clk > 120 then table.remove(clk, 1) end
  local least = math.huge
  for i = 1, #clk do least = math.min(least, clk[i]) end
  return math.min(0.1, now - gt - least)
end

local LOADOUT = {
  { hash = 0xA2719263, name = "Unarmed", slot = 7, icon = "gta_unarmed.svg" },
  { hash = 0x1B06D571, name = "Pistol", slot = 3, icon = "gta_pistol.svg" },
  { hash = 0x2BE6766B, name = "SMG", slot = 4, icon = "gta_smg.svg" },
  { hash = 0x83BF0278, name = "Carbine Rifle", slot = 5, icon = "gta_rifle.svg" },
  { hash = 0x1D073A89, name = "Pump Shotgun", slot = 8, icon = "gta_shotgun.svg", pellets = 6 },
}
local WEAPON = {}
for _, w in ipairs(LOADOUT) do WEAPON[w.hash] = w end
local lastWeapon

local function parsePed(f)
  ped.seq = tonumber(f[2]) or 0
  stat.pkts = stat.pkts + 1
  ped.gx, ped.gy, ped.gz = tonumber(f[3]) or 0, tonumber(f[4]) or 0, tonumber(f[5]) or 0
  ped.heading = tonumber(f[6]) or 0
  ped.vx, ped.vy, ped.vz = tonumber(f[7]) or 0, tonumber(f[8]) or 0, tonumber(f[9]) or 0
  ped.flags = tonumber(f[10]) or 0
  ped.weapon = (tonumber(f[11]) or 0) % 4294967296
  if ped.weapon ~= lastWeapon then
    if lastWeapon and WEAPON[ped.weapon] then pcall(ui_message, WEAPON[ped.weapon].name, 2, "gtaBridgeWeapon") end
    lastWeapon = ped.weapon
  end
  ped.health = tonumber(f[12]) or 0
  local sk = {}
  if f[13] and f[13] ~= "" then
    local n = 0
    for v in string.gmatch(f[13], "[^,]+") do
      n = n + 1
      sk[n] = tonumber(v) or 0
    end
  end
  ped.muz = nil
  ped.muzd = nil
  if f[16] and f[16] ~= "" then
    local m, n = {}, 0
    for v in string.gmatch(f[16], "[^,]+") do
      n = n + 1
      m[n] = tonumber(v)
    end
    if n >= 3 and m[1] and m[2] and m[3] then ped.muz = m end
    ped.muzd = (n >= 6 and m[4] and m[5] and m[6]) and { m[4], m[5], m[6] } or nil
  end
  local shots = tonumber(f[15])
  if shots and ped.shots and shots > ped.shots then ped.shotsDue = math.min(8, (ped.shotsDue or 0) + shots - ped.shots) end
  ped.shots = shots or ped.shots
  local now = socket.gettime()
  local gt = tonumber(f[14])
  if gt then now = now - packetAge(now, gt) end
  ped.sk = sk
  ped.t = now
  if #sk >= 54 then
    skHist[#skHist + 1] = { t = now, sk = sk, gx = ped.gx, gy = ped.gy, gz = ped.gz }
    if #skHist > 24 then table.remove(skHist, 1) end
  end
  ped.fresh = true
end

local leadSec = 0.05
local function pump()
  if not udp then return end
  for _ = 1, 64 do
    local data = udp:receive()
    if not data then break end
    if data:sub(1, 2) == "P|" then
      parsePed(split(data, "|"))
    elseif data:sub(1, 2) == "D|" then
      log("I", logTag, "gta: " .. data:sub(3))
    elseif data:sub(1, 2) == "A|" then
      local ms = tonumber(data:sub(3))
      if ms then leadSec = leadSec * 0.9 + math.max(0.02, math.min(0.1, ms / 1000)) * 0.1 end
    end
  end
  if ped.fresh and socket.gettime() - ped.t > cfg.staleTimeout then
    ped.fresh = false
  end
end

local function getWalker()
  local walk = extensions.gameplay_walk
  if not walk then return nil end
  return walk.getCurrentUnicycle()
end

local function ensureWalker(bx, by, bz)
  extensions.load("gameplay_walk")
  local walk = extensions.gameplay_walk
  if not walk then
    log("E", logTag, "gameplay_walk extension not available")
    return nil
  end
  if not walk.isWalking() then
    walk.setWalkingMode(true, vec3(bx, by, bz), nil, true)
  end
  return walk.getCurrentUnicycle()
end

local walkerFeet = vec3()
local walkerHave = false
local needOffset = false
local arriveT
local function settled() return not needOffset and not arriveT end
local tpCheck, tpSent, tpTries = false, 0, 0

local function moveVeh(u, pos)
  local ok, r = pcall(u.getRotation, u)
  if ok and r then
    return pcall(u.setPositionRotation, u, pos.x, pos.y, pos.z, r.x, r.y, r.z, r.w)
  end
  return pcall(u.setPositionRotation, u, pos.x, pos.y, pos.z, 0, 0, 0, 1)
end
local lastGround

local waters
local function findWaters()
  waters = {}
  for _, cls in ipairs({ "WaterPlane", "WaterBlock" }) do
    for _, name in ipairs(scenetree.findClassObjects(cls) or {}) do
      local ok, p, s = pcall(function() local o = scenetree.findObject(name) return o:getPosition(), o:getScale() end)
      if ok and p and cls == "WaterPlane" then
        waters[#waters + 1] = { z = p.z }
        log("I", logTag, string.format("water: %s '%s' at height %.2f", cls, tostring(name), p.z))
      elseif ok and p and s then
        waters[#waters + 1] = { z = p.z, x0 = p.x - s.x * 0.5, x1 = p.x + s.x * 0.5, y0 = p.y - s.y * 0.5, y1 = p.y + s.y * 0.5 }
        log("I", logTag, string.format("water: %s '%s' centre (%.1f, %.1f, %.2f) size (%.1f, %.1f, %.2f)", cls, tostring(name), p.x, p.y, p.z, s.x, s.y, s.z))
      else
        log("W", logTag, string.format("water: could not read %s '%s': %s", cls, tostring(name), tostring(p)))
      end
    end
  end
  if #waters == 0 then log("I", logTag, "water: none found on this map") end
end
local function waterAt(x, y)
  if not cfg.swim then return nil end
  if not waters then findWaters() end
  local best
  for _, w in ipairs(waters) do
    if (not w.x0 or (x >= w.x0 and x <= w.x1 and y >= w.y0 and y <= w.y1)) and (not best or w.z > best) then best = w.z end
  end
  return best
end
local walkerWater
local FOOT = { { 0.2, 0 }, { -0.2, 0 }, { 0, 0.2 }, { 0, -0.2 } }
local dropN, lostN = 0, 0
local function groundFromAbove(x, y)
  local cp = core_camera.getPosition and core_camera.getPosition()
  if not cp then return nil end
  local ok, d = pcall(castRayStatic, vec3(x, y, cp.z + 1), vec3(0, 0, -1), 400)
  if ok and d and d < 400 then return cp.z + 1 - d end
end
local function readWalker()
  local u = getWalker()
  if not u then walkerHave = false return nil end
  walkerId = u:getID()
  local p = u:getPosition()
  if not needOffset and ped.fresh and lastGround then
    local ex = slow * math.max(0, math.min(0.08, socket.gettime() - ped.t))
    local bx, by = gtaToBeam(ped.gx + (ped.vx or 0) * ex, ped.gy + (ped.vy or 0) * ex, ped.gz)
    local feet = lastGround
    if settled() and ped.gz then
      feet = ped.gz + cfg.oz - 1.0
      if math.floor((ped.flags or 0) / 65536) % 2 == 1 then feet = ped.gz + cfg.oz - 0.5
      elseif ped.sk and #ped.sk >= 54 then
        local low = math.min(ped.sk[42], ped.sk[54])
        if (ped.flags or 0) % 2 == 1 then
          for i = 3, 54, 3 do low = math.min(low, ped.sk[i]) end
        end
        feet = low + cfg.oz - ((ped.flags or 0) % 2 == 1 and 0.05 or 0.10)
      end
    end
    local best
    for i = 1, 4 do
      local ok, d = pcall(castRayStatic, vec3(bx + FOOT[i][1], by + FOOT[i][2], feet + 0.9), vec3(0, 0, -1), 80)
      if ok and d and d < 80 then
        local g = feet + 0.9 - d
        if g <= feet + 0.45 and (not best or g > best) then best = g end
      end
    end
    if not best then
      lostN = lostN + 1
      if lostN > 20 then
        local ok, d = pcall(castRayStatic, vec3(bx, by, feet + 0.45), vec3(0, 0, -1), 400)
        if ok and d and d < 400 then lastGround, dropN, lostN = feet + 0.45 - d, 0, 0 end
      end
    else lostN = 0 end
    if best then
      if best >= lastGround - 0.6 then
        lastGround, dropN = best, 0
      else
        dropN = dropN + 1
        if dropN >= (feet > lastGround + 0.5 and 1 or 3) then lastGround, dropN = best, 0 end
      end
    end
    walkerFeet:set(bx, by, lastGround)
    walkerWater = waterAt(bx, by)
    local tgt = vec3(bx, by, lastGround - 1000)
    local okc, gname = pcall(core_camera.getActiveGlobalCameraName)
    if okc and not gname and ped.sk and #ped.sk >= 12 then
      local hx, hy, hz = gtaToBeam(ped.sk[10], ped.sk[11], ped.sk[12])
      local h = math.rad(ped.heading or 0)
      local fx, fy = rotZ(-math.sin(h), math.cos(h), yawRad)
      local okn, n = pcall(function()
        local cn = core_camera.getDriverData(u)
        return vec3(u:getNodePosition(cn or 0))
      end)
      tgt = vec3(hx + fx * 0.12, hy + fy * 0.12, hz + 0.07) - (okn and n or vec3(0, 0, 1.6))
    end
    moveVeh(u, tgt)
    if socket.gettime() - S.dbgT > 2 then
      S.dbgT = socket.gettime()
      local gp = u:getPosition()
      log("I", logTag, string.format("dbg fpv=%s ground=%.2f walker=(%.2f,%.2f,%.2f) target=(%.2f,%.2f,%.2f) globalCam=%s",
        tostring(okc and not gname), lastGround, gp.x, gp.y, gp.z, tgt.x, tgt.y, tgt.z, tostring(gname)))
    end
    pcall(u.setMeshAlpha, u, 0, "", false)
    walkerHave = true
    return u
  end
  local gz = p.z
  if p.z < S.lastGroundFloor then gz = groundFromAbove(p.x, p.y) or lastGround or p.z
  else
    local ok, d = pcall(castRayStatic, vec3(p.x, p.y, p.z + 3), vec3(0, 0, -1), 14)
    if ok and d and d < 14 then gz = p.z + 3 - d end
  end
  walkerFeet:set(p.x, p.y, gz)
  walkerWater = waterAt(p.x, p.y)
  lastGround = gz
  walkerHave = true
  return u
end

local function computeOffset()
  if not readWalker() then return false end
  local rx, ry = rotZ(cfg.anchorX, cfg.anchorY, yawRad)
  cfg.ox = walkerFeet.x - rx
  cfg.oy = walkerFeet.y - ry
  cfg.oz = walkerFeet.z - cfg.anchorZ
  saveConfig()
  log("I", logTag, string.format("anchored: offset = %.2f, %.2f, %.2f", cfg.ox, cfg.oy, cfg.oz))
  return true
end

local function sendWalker()
  if not (engaged and readWalker()) then return end
  local gx, gy, gz = beamToGta(walkerFeet.x, walkerFeet.y, walkerFeet.z)
  seq = seq + 1
  send(string.format("W|%d|%.3f|%.3f|%.3f|%.3f", seq, gx, gy, gz, walkerWater and (walkerWater - cfg.oz) or -9999))
end

local limbShape = "/art/shapes/gtaBridge/limb.dae"
local ballShape = "/art/shapes/gtaBridge/ball.dae"
local thickness = {0.30, 0.26, 0.10,  0.09, 0.10, 0.09, 0.07,  0.09, 0.10, 0.09, 0.07,  0.12, 0.14, 0.10,  0.12, 0.14, 0.10}
local segs, head = {}, nil
local puppetId, puppetLoadedAt, puppetErr

local function newObj(shape, name)
  local o = createObject("TSStatic")
  if not o then return nil end
  o:setField("shapeName", 0, shape)
  o:setField("collisionType", 0, "None")
  o:registerObject(name)
  if scenetree.MissionGroup then scenetree.MissionGroup:addObject(o) end
  return o
end

local bodyId, bodySpawnT, bodyLoaded, bodyParked
local function bodyVeh()
  local v = bodyId and be:getObjectByID(bodyId)
  if v then return v end
  for i = 0, be:getObjectCount() - 1 do
    local o = be:getObject(i)
    local ok, jb = pcall(o.getJBeamFilename, o)
    if ok and jb == "gta_body" then bodyId = o:getId() return o end
  end
  bodyId = nil
end
local function parkBody()
  local v = bodyVeh()
  if v and bodyLoaded and not bodyParked then
    v:queueLuaCommand("gtaBody.park()")
    bodyParked = true
  end
end
local function deleteBody()
  local v = bodyVeh()
  if v then pcall(v.delete, v) end
  bodyId, bodySpawnT, bodyLoaded, bodyParked = nil, nil, nil, nil
end

local findPuppets
local spawnedAt = 0
local function destroyBody()
  deleteBody()
  for _, o in pairs(segs) do pcall(o.delete, o) end
  if head then pcall(head.delete, head) end
  segs, head = {}, nil
  if puppetId then
    local v = be:getObjectByID(puppetId)
    if v then pcall(v.delete, v) end
    puppetId, puppetLoadedAt = nil, nil
  end
  for _, o in ipairs(findPuppets()) do pcall(o.delete, o) end
  spawnedAt = 0
end

local function place(o, cx, cy, cz, qx, qy, qz, qw, sx, sy, sz)
  local ok = pcall(o.setPosRot, o, cx, cy, cz, qx, qy, qz, qw)
  if not ok then
    local ok2, err = pcall(function()
      local m = QuatF(qx, qy, qz, qw):getMatrix()
      m:setPosition(Point3F(cx, cy, cz))
      o:setTransform(m)
    end)
    if not ok2 and S.bodyErr ~= err then S.bodyErr = err; log("E", logTag, "cannot pose body object: " .. tostring(err)) end
  end
  o.scale = vec3(sx, sy, sz)
end

local function skeletonPoints()
  if not (ped.fresh and ped.sk and #ped.sk >= 54) then return nil end
  local ex = slow * math.max(0, math.min(0.08, socket.gettime() - ped.t))
  local dx, dy = (ped.vx or 0) * ex, (ped.vy or 0) * ex
  local pts, sk = {}, ped.sk
  for i = 1, 18 do
    local o = (i - 1) * 3
    pts[i] = vec3(gtaToBeam(sk[o + 1] + dx, sk[o + 2] + dy, sk[o + 3]))
  end
  return pts
end

local function drawBody(pts)
  if not cfg.renderBody then return end
  for i, b in ipairs(bones) do
    local o = segs[i]
    if not o then
      o = newObj(limbShape, "gtaBridge_seg" .. i)
      segs[i] = o
    end
    if o then
      local a, c = pts[b[1]], pts[b[2]]
      local d = c - a
      local len = d:length()
      if len > 1e-4 then
        d = d / len
        local up = vec3(0, 0, 1)
        if math.abs(d.z) > 0.98 then up = vec3(1, 0, 0) end
        local right = d:cross(up):normalized()
        up = right:cross(d)
        local qx, qy, qz, qw = quatFromBasis(right.x, right.y, right.z, d.x, d.y, d.z, up.x, up.y, up.z)
        if cfg.flipQuat then qx, qy, qz = -qx, -qy, -qz end
        local m = (a + c) * 0.5
        place(o, m.x, m.y, m.z, qx, qy, qz, qw, thickness[i], len, thickness[i])
      end
    end
  end
  head = head or newObj(ballShape, "gtaBridge_head")
  if head then
    local h = pts[4]
    place(head, h.x, h.y, h.z, 0, 0, 0, 1, 0.22, 0.22, 0.22)
  end
end

findPuppets = function()
  local list = {}
  for i = 0, be:getObjectCount() - 1 do
    local o = be:getObject(i)
    local ok, hit = pcall(function()
      local n = tostring(o:getField("name", "") or "")
      return o.jbeam == "gta_puppet" or o:getJBeamFilename() == "gta_puppet" or n:find("gtaPuppet", 1, true)
    end)
    if o and ok and hit then list[#list + 1] = o end
  end
  return list
end
local function drawPuppet(pts)
  local v = puppetId and be:getObjectByID(puppetId)
  if not v then
    local all = findPuppets()
    for i = 2, #all do pcall(all[i].delete, all[i]) end
    if all[1] then
      puppetId, puppetLoadedAt = all[1]:getId(), puppetLoadedAt or socket.gettime()
      return
    end
    puppetId = nil
    if spawnedAt > 0 then return end
    spawnedAt = socket.gettime()
    local ok, res = pcall(function()
      local o = sanitizeVehicleSpawnOptions("gta_puppet", {vehicleName = "gtaPuppet", autoEnterVehicle = false})
      o.pos, o.rot = pts[1], quat(0, 0, 0, 1)
      return core_vehicles.spawnNewVehicle(o.model, o)
    end)
    if ok and res then
      puppetId = res:getId()
      puppetLoadedAt = socket.gettime()
      log("I", logTag, "spawned gta_puppet vehicle id " .. tostring(puppetId))
    elseif not ok and puppetErr ~= res then
      puppetErr = res
      log("E", logTag, "cannot spawn gta_puppet: " .. tostring(res))
    end
    return
  end
  if puppetLoadedAt then
    if socket.gettime() - puppetLoadedAt < 1.0 then return end
    v:queueLuaCommand("extensions.load('gtaPuppet')")
    v:setPositionRotation(pts[1].x, pts[1].y, pts[1].z, 0, 0, 0, 1)
    puppetLoadedAt = nil
    return
  end
  if (v:getPosition() - pts[1]):length() > 25 then
    v:setPositionRotation(pts[1].x, pts[1].y, pts[1].z, 0, 0, 0, 1)
    return
  end
  local t = {}
  for i = 1, 18 do t[#t + 1] = string.format("%.3f,%.3f,%.3f", pts[i].x, pts[i].y, pts[i].z) end
  v:queueLuaCommand("gtaPuppet.set('" .. table.concat(t, ",") .. "')")
end

local cam = {}
local function chaseCam(pts, cd)
  if not cfg.thirdPerson then return end
  local fwd = quat(cd.res.rot) * vec3(0, 1, 0)
  local right = fwd:cross(vec3(0, 0, 1)):normalized()
  local now = os.clock()
  local dt = math.min(0.1, now - (cam.t or now)); cam.t = now
  local hz = pts[4].z - walkerFeet.z
  cam.hz = cam.hz and cam.hz + (hz - cam.hz) * (1 - math.exp(-dt * 3)) or hz
  local goal = vec3(walkerFeet.x, walkerFeet.y, walkerFeet.z + cam.hz + cfg.camHeight)
  if not cam.pivot or (cam.pivot - goal):length() > 5 then cam.pivot = goal; cam.vel = vec3(0, 0, 0); cam.dist = cfg.camDist end
  local w = cfg.camPivotRate * 1.6
  local e = math.exp(-w * dt)
  local ch = cam.pivot - goal
  local tmp = (cam.vel + ch * w) * dt
  cam.vel = (cam.vel - tmp * w) * e
  cam.pivot = goal + (ch + tmp) * e
  local pivot = cam.pivot + right * cfg.camShoulder
  local wantDist = cfg.camDist
  local ok, d = pcall(castRayStatic, pivot, -fwd, wantDist + 0.3)
  if ok and d and d < wantDist + 0.3 then wantDist = math.max(0.4, d - 0.3) end
  if wantDist < cam.dist then cam.dist = wantDist
  else cam.dist = cam.dist + (wantDist - cam.dist) * (1 - math.exp(-dt * cfg.camPushOut)) end
  cam.pos = pivot - fwd * cam.dist
  if walkerWater and math.floor((ped.flags or 0) / 65536) % 2 == 1 then cam.pos.z = math.max(cam.pos.z, walkerWater + 0.3) end
  cd.res.pos:set(cam.pos)
  core_camera.setPosition(0, cam.pos)
end

local function drawSkeleton(pts)
  if not cfg.drawSkeleton then return end
  local col = ColorF(0.1, 1, 0.3, 1)
  for _, b in ipairs(bones) do
    debugDrawer:drawLine(pts[b[1]], pts[b[2]], col)
  end
  debugDrawer:drawSphere(pts[4], 0.08, ColorF(1, 0.2, 0.2, 1))
end

local hist = {}
local function predictPose(now, p, f)
  local yaw, pitch = math.atan2(f.x, f.y), math.asin(math.max(-1, math.min(1, f.z)))
  local n = #hist
  if n == 0 or now - hist[n].t > 0.004 then
    hist[n + 1] = { t = now, yaw = yaw, pitch = pitch, px = p.x, py = p.y, pz = p.z, fx = walkerFeet.x, fy = walkerFeet.y, fz = walkerFeet.z }
    if n + 1 > 60 then table.remove(hist, 1) end
    n = #hist
  end
  local ref
  for i = n, 1, -1 do
    if now - hist[i].t >= 0.06 then ref = hist[i] break end
  end
  local lead = (cfg.predict and ref) and math.min(0.08, leadSec) * cfg.predictGain or 0
  if not ref or lead <= 0 then return p, f, walkerFeet end
  local dt = now - ref.t
  if dt > 0.3 then return p, f, walkerFeet end
  local dyaw = yaw - ref.yaw
  if dyaw > math.pi then dyaw = dyaw - 2 * math.pi elseif dyaw < -math.pi then dyaw = dyaw + 2 * math.pi end
local function lim(x) return math.max(-0.5, math.min(0.5, x)) end
  local yawP = yaw + lim(dyaw / dt * lead)
  local pitchP = math.max(-1.45, math.min(1.45, pitch + lim((pitch - ref.pitch) / dt * lead)))
  local cp = math.cos(pitchP)
  local fP = vec3(math.sin(yawP) * cp, math.cos(yawP) * cp, math.sin(pitchP))
  local k = lead / dt
  local dpx, dpy, dpz = (p.x - ref.px) * k, (p.y - ref.py) * k, (p.z - ref.pz) * k
  local dl = math.sqrt(dpx * dpx + dpy * dpy + dpz * dpz)
  if dl > 3 then dpx, dpy, dpz = dpx * 3 / dl, dpy * 3 / dl, dpz * 3 / dl end
  local feetP = vec3(walkerFeet.x + (walkerFeet.x - ref.fx) * k, walkerFeet.y + (walkerFeet.y - ref.fy) * k, walkerFeet.z)
  local cx, cy, cz = feetP.x, feetP.y, feetP.z + 1
  local ox, oy, oz = p.x + dpx - cx, p.y + dpy - cy, p.z + dpz - cz
  local r0 = math.sqrt((p.x - walkerFeet.x) ^ 2 + (p.y - walkerFeet.y) ^ 2 + (p.z - walkerFeet.z - 1) ^ 2)
  local r1 = math.sqrt(ox * ox + oy * oy + oz * oz)
  local g = (r1 > 0.05) and r0 / r1 or 1
  local pP = vec3(cx + ox * g, cy + oy * g, cz + oz * g)
  return pP, fP, feetP
end

local sunObj, sunT, sunV = nil, 0, nil
local function sunDir()
  local now = socket.gettime()
  if now - sunT < 0.5 then return sunV end
  sunT = now
  local ok = pcall(function()
    if not sunObj then
      local names = scenetree.findClassObjects("ScatterSky")
      sunObj = names and names[1] and scenetree.findObject(names[1]) or nil
    end
    local az, el = sunObj and tonumber(sunObj.azimuth), sunObj and tonumber(sunObj.elevation)
    if az and el then
      local a, e = math.rad(az), math.rad(el)
      local x, y, z = math.sin(a) * math.cos(e), math.cos(a) * math.cos(e), math.sin(e)
      if cfg.sunFlip then x, y = -x, -y end
      sunV = z > 0.03 and { x, y, z } or nil
      if now - S.sunLogT > 10 then
        S.sunLogT = now
        log("I", logTag, string.format("sun azimuth=%.1f elevation=%.1f dir=(%.2f,%.2f,%.2f)", az, el, x, y, z))
      end
    else
      sunV = nil
    end
  end)
  if not ok then sunObj, sunV = nil, nil end
  return sunV
end

local function bodyPoints()
  if not settled() or not (ped.fresh and ped.gx and #skHist > 0) then return nil end
  local now = socket.gettime()
  local e
  for i = #skHist, 1, -1 do
    e = skHist[i]
    if e.t <= now - leadSec then break end
  end
  local ex = slow * math.max(0, math.min(0.08, now - ped.t))
  local dx, dy, dz = ped.gx + (ped.vx or 0) * ex - e.gx, ped.gy + (ped.vy or 0) * ex - e.gy, ped.gz - e.gz
  local pts, sk = {}, e.sk
  for i = 1, 18 do
    local o = (i - 1) * 3
    pts[i] = vec3(gtaToBeam(sk[o + 1] + dx, sk[o + 2] + dy, sk[o + 3] + dz))
  end
  local tx, ty, tz = 0, 0, 0
  if (ped.flags or 0) % 2 == 0 then
    local h = math.rad(ped.heading or 0)
    tx, ty = rotZ(-math.sin(h), math.cos(h), yawRad)
    tx, ty, tz = tx * 0.17, ty * 0.17, -0.05
  end
  pts[19] = pts[15] + vec3(tx, ty, tz)
  pts[20] = pts[18] + vec3(tx, ty, tz)
  return pts
end

local shade, shadeT = { 0, 0, 0, 0 }, 0
local casting = false
local function updateShade(sv)
  local now = socket.gettime()
  local k = math.min(1, (now - shadeT) / 0.12); shadeT = now
  local t = { 0, 0, 0, 0 }
  if sv and sv[3] > 0.03 then
    local x, y, g = walkerFeet.x, walkerFeet.y, walkerFeet.z
    local c = ped.fresh and ped.gz and (ped.gz + cfg.oz) or (g + 1)
    local flat = math.sqrt(sv[1] * sv[1] + sv[2] * sv[2])
    local reach = math.min(4, 1.7 * flat / sv[3])
    local fx, fy = flat > 0.001 and -sv[1] / flat * reach or 0, flat > 0.001 and -sv[2] / flat * reach or 0
    local from = { vec3(x, y, c - 0.6), vec3(x, y, c + 0.7), vec3(x, y, g + 0.08), vec3(x + fx, y + fy, g + 0.08) }
    for i = 1, 4 do
      local ok, d = pcall(castRayStatic, from[i], vec3(sv[1], sv[2], sv[3]), 300)
      if ok and d and d < 300 then t[i] = 1 end
    end
  end
  for i = 1, 4 do shade[i] = shade[i] + (t[i] - shade[i]) * k end
end

local function sendPose(cd)
  if not engaged then return end
  local p = cd and vec3(cd.res.pos) or (cam.pos and os.clock() - (cam.t or -1) < 0.25) and cam.pos or (core_camera.getPosition and core_camera.getPosition())
  local q = cd and quat(cd.res.rot) or core_camera.getQuat and core_camera.getQuat()
  if not p or not q then return end
  local f = q * vec3(0, 1, 0)
  local okf, fov = pcall(core_camera.getFovDeg)
  if cd and cd.res.fov then okf, fov = true, cd.res.fov end
  fov = (okf and fov and fov > 1) and fov or 60
  local pP, fP, feetP = p, f, walkerFeet
  if walkerHave then pP, fP, feetP = predictPose(socket.gettime(), p, f) end
  local px, py, pz = beamToGta(pP.x, pP.y, pP.z)
  local gx, gy, gz = dirToGta(fP.x, fP.y, fP.z)
  seq = seq + 1
  send(string.format("K|%d|%.4f|%.4f|%.4f|%.5f|%.5f|%.5f|%.3f", seq, px, py, pz, gx, gy, gz, fov * cfg.fovMul))
  if udp and walkerHave and settled() then
    local zc = (walkerFeet.x - p.x) * f.x + (walkerFeet.y - p.y) * f.y + (walkerFeet.z + 1.0 - p.z) * f.z
    local sv = sunDir() or { 0, 0, 0 }
    updateShade(sv)
    local pct = (shade[1] + shade[2]) * 0.5
    if pct > 0.9 then casting = true elseif pct < 0.8 then casting = false end
    local cx, cy, cz = dirToGta(sv[1], sv[2], sv[3])
    send(string.format("H|%d|%.4f|%.4f|%.4f", casting and 1 or 0, cx, cy, cz))
    local air = 0
    if ped.fresh and ped.gz then air = math.max(0, math.min(300, ped.gz - (walkerFeet.z - cfg.oz) - 1.0 - 0.06)) end
    local bodyH, bodyMode, bodyAt = 0, 0, nil
    if ped.fresh and ped.sk and #ped.sk >= 54 then
      local g0 = walkerFeet.z - cfg.oz
      local sk = ped.sk
      bodyH = 0.10 * sk[12] + 0.30 * sk[6] + 0.30 * sk[3] + 0.15 * sk[42] + 0.15 * sk[51] - g0
      local fl = ped.flags or 0
      if math.floor(fl / 2048) % 2 == 1 or math.floor(fl / 32768) % 2 == 1 then bodyMode = 1 end
      if math.floor(fl / 2048) % 2 == 1 or (bodyMode == 1 and math.floor(fl / 16384) % 2 == 1) then bodyMode = 2 end
      if bodyMode > 0 then
        local hx, hy = gtaToBeam(sk[10], sk[11], 0)
        bodyAt = vec3(hx, hy, walkerFeet.z)
        bodyH = sk[12] - g0 + cfg.headTop
        if math.floor(fl / 2048) % 2 == 1 and math.floor(fl / 16384) % 2 == 0 then bodyMode = 4 end
      elseif fl % 2 == 1 or math.floor(fl / 64) % 2 == 1 or math.floor(fl / 65536) % 2 == 1 or sk[12] - sk[3] < 0.4 then
        bodyMode = 3
        local wx = 0.10 * sk[10] + 0.30 * sk[4] + 0.30 * sk[1] + 0.15 * sk[40] + 0.15 * sk[49]
        local wy = 0.10 * sk[11] + 0.30 * sk[5] + 0.30 * sk[2] + 0.15 * sk[41] + 0.15 * sk[50]
        if math.floor(fl / 65536) % 2 == 1 and walkerWater then
          local sx, sy, sz, n = 0, 0, 0, 0
          for i = 1, 52, 3 do
            if sk[i + 2] + cfg.oz > walkerWater - 0.05 then
              local w = i == 10 and 3 or 1
              sx, sy, sz, n = sx + sk[i] * w, sy + sk[i + 1] * w, sz + sk[i + 2] * w, n + w
            end
          end
          if n > 0 then wx, wy, bodyH = sx / n, sy / n, sz / n - g0 end
        end
        local bx, by = gtaToBeam(wx, wy, 0)
        bodyAt = vec3(bx, by, walkerFeet.z)
      end
    end
    local wf, wfP = bodyAt or walkerFeet, bodyAt or feetP
    pcall(udp.sendto, udp, string.format("Q|%.4f|%.4f|%.4f|%.5f|%.5f|%.5f|%.3f|%.3f|%.3f|%.4f|%.4f|%.4f|%.4f|%.4f|%.4f|%.5f|%.5f|%.5f|%.4f|%.4f|%.4f|%.4f|%.4f|%.4f|%.3f|%.3f|%d|%.3f|%.2f|%.2f|%.2f|%.2f|%.2f",
      p.x, p.y, p.z, f.x, f.y, f.z, fov, fov * cfg.fovMul, zc, wf.x, wf.y, wf.z,
      pP.x, pP.y, pP.z, fP.x, fP.y, fP.z, wfP.x, wfP.y, wfP.z, sv[1], sv[2], sv[3], air, bodyH, bodyMode,
      walkerWater and math.max(0, walkerWater - walkerFeet.z) * (math.floor((ped.flags or 0) / 65536) % 2 == 1 and -1 or 1) or 0,
      casting and 0 or shade[1], casting and 0 or shade[2], shade[3], shade[4],
      (core_quickAccess and core_quickAccess.isEnabled()) and cfg.wheelGhost or 1), cfg.host, 47202)
    local pts = (bodyMode == 0 or bodyMode == 3) and bodyPoints()
    if pts then
      local t = {}
      for i = 1, 20 do t[i] = string.format("%.3f|%.3f|%.3f", pts[i].x, pts[i].y, pts[i].z) end
      pcall(udp.sendto, udp, "S|" .. table.concat(t, "|"), cfg.host, 47202)
    end
  end
end

local function sendCamera()
  if not engaged then return end
  local f = core_camera and core_camera.getForward and core_camera.getForward()
  if not f then return end
  local gx, gy, gz = dirToGta(f.x, f.y, f.z)
  seq = seq + 1
  send(string.format("C|%d|%.4f|%.4f|%.4f", seq, gx, gy, gz))
  local nowS = socket.gettime()
  if cfg.syncTime and nowS - (S.lastTimeSend or 0) > 2 then
    S.lastTimeSend = nowS
    local okt, tod = pcall(function() return core_environment.getTimeOfDay() end)
    if okt and tod and tod.time then
      send(string.format("L|%d|%.3f", seq, ((tod.time + 0.5) % 1) * 24))
    end
  end
end

local gtaByModel = {
  atv = "blazer", autobello = "panto", barstow = "vigero", bastion = "buffalo", bluebuck = "emperor", bolide = "infernus",
  burnside = "tornado", bx = "futo", citybus = "bus", covet = "blista", dumptruck = "tiptruck", etk800 = "schafter2", etkc = "zion",
  etki = "oracle", fullsize = "stanier", hopper = "mesa", lansdale = "minivan", legran = "ingot", md_series = "mule",
  midsize = "primo", midtruck = "benson", miramar = "regina", moonhawk = "sabregt", nine = "tornado", pessima = "premier",
  pickup = "bison", pigeon = "panto", racetruck = "hauler", roamer = "granger", rockbouncer = "bfinjection", sbr = "elegy2",
  scintilla = "cheetah", simple_traffic = "asea", sunburst2 = "sultan", us_semi = "phantom", utv = "bfinjection", van = "burrito3",
  vivace = "blista", wendover = "ruiner", wigeon = "panto", wl40 = "bulldozer",
  dryvan = "trailers", tanker = "tanker", flatbed = "trflat", tiltdeck = "trflat", containerTrailer = "docktrailer",
}
local gtaByStyleFirst = {
  { "ambulance", "ambulance" }, { "fire", "firetruk" }, { "box truck", "mule" }, { "box", "mule" }, { "cement", "mixer" }, { "mixer", "mixer" },
  { "dump", "tiptruck" }, { "tow", "towtruck" }, { "rollback", "flatbed" }, { "flatbed", "flatbed" }, { "garbage", "trash" },
  { "bus", "bus" }, { "limo", "stretch" },
}
local gtaByStyle = {
  { "semi", "phantom" }, { "minivan", "minivan" }, { "van", "burrito3" }, { "pickup", "bison" }, { "suv", "granger" },
  { "wagon", "ingot" }, { "estate", "ingot" }, { "hatch", "blista" }, { "convertible", "zion2" }, { "roadster", "zion2" },
  { "coupe", "zion" }, { "sedan", "premier" }, { "saloon", "premier" }, { "supercar", "cheetah" }, { "sports", "elegy2" },
  { "buggy", "bfinjection" }, { "atv", "blazer" }, { "quad", "blazer" }, { "motorcycle", "bati" }, { "bike", "bati" },
}
local carInfo = {}
local function carFor(veh, id)
  local jb = veh:getJBeamFilename()
  local key = jb .. "|" .. tostring(veh.partConfig)
  local ci = carInfo[id]
  if ci and ci.key == key then return ci end
  ci = { key = key, model = "" }
  carInfo[id] = ci
  local typ, style = "", ""
  pcall(function()
    local d = core_vehicles.getVehicleDetails(id)
    local m, c = d.model or {}, d.configs or {}
    typ = string.lower(tostring(m.Type or ""))
    style = string.lower(tostring(c["Body Style"] or m["Body Style"] or ""))
  end)
  if typ == "prop" then ci.skip = true return ci end
  for _, e in ipairs(gtaByStyleFirst) do
    if style:find(e[1], 1, true) then ci.model = e[2] break end
  end
  if ci.model == "" then ci.model = gtaByModel[jb] or "" end
  if ci.model == "" then
    for _, e in ipairs(gtaByStyle) do
      if style:find(e[1], 1, true) then ci.model = e[2] break end
    end
  end
  if ci.model == "" and typ == "trailer" then ci.skip = true end
  log("I", logTag, string.format("car %d: %s (type '%s', body '%s') -> GTA '%s'%s", id, jb, typ, style, ci.model, ci.skip and " (not mirrored)" or ""))
  return ci
end

local function sendWorld()
  if not (engaged and cfg.cars and walkerHave) then return end
  local center = walkerFeet
  local list = {}
  for _, veh in ipairs(getAllVehicles()) do
    local id = veh:getID()
    local jb = veh:getJBeamFilename()
    if jb ~= "unicycle" and jb ~= "gta_body" and veh:getActive() and be:getObjectOOBBIsInitialized(id) and not carFor(veh, id).skip then
      local c = vec3(be:getObjectOOBBCenterXYZ(id))
      local dist = c:distance(center)
      if dist <= cfg.carRadius then
        list[#list + 1] = { veh = veh, id = id, c = c, dist = dist }
      end
    end
  end
  table.sort(list, function(a, b) return a.dist < b.dist end)

  for i = 1, math.min(#list, cfg.carMax) do
    local e = list[i]
    local veh, id = e.veh, e.id
    local dir = vec3(veh:getDirectionVector()):normalized()
    local up = vec3(veh:getDirectionVectorUp()):normalized()
    local right = dir:cross(up):normalized()
    up = right:cross(dir):normalized()

    local hx, hy, hz = 0, 0, 0
    for a = 0, 2 do
      local ax = vec3(be:getObjectOOBBHalfAxisXYZ(id, a))
      hx = hx + math.abs(ax:dot(right))
      hy = hy + math.abs(ax:dot(dir))
      hz = hz + math.abs(ax:dot(up))
    end

    local cx, cy, cz = beamToGta(e.c.x, e.c.y, e.c.z)
    local rx, ry, rz = dirToGta(right.x, right.y, right.z)
    local fx, fy, fz = dirToGta(dir.x, dir.y, dir.z)
    local ux, uy, uz = dirToGta(up.x, up.y, up.z)
    local qx, qy, qz, qw = quatFromBasis(rx, ry, rz, fx, fy, fz, ux, uy, uz)
    local ci, tv = carFor(veh, id), socket.gettime()
    local vx, vy, vz = veh:getVelocityXYZ()
    local k = math.min(1, (tv - (ci.vt or 0)) / 0.15)
    ci.vt, ci.vx, ci.vy, ci.vz = tv, (ci.vx or vx) + (vx - (ci.vx or vx)) * k, (ci.vy or vy) + (vy - (ci.vy or vy)) * k, (ci.vz or vz) + (vz - (ci.vz or vz)) * k
    vx, vy, vz = dirToGta(ci.vx, ci.vy, ci.vz)

    local has, dgx, dgy, dgz = 0, 0, 0, 0
    pcall(function()
      local dn = core_camera.getDriverData(veh)
      if dn then
        local dp = veh:getPosition() + veh:getNodePosition(dn)
        dgx, dgy, dgz = beamToGta(dp.x, dp.y, dp.z)
        has = 1
      end
    end)
    send(string.format("V|%d|%.3f|%.3f|%.3f|%.5f|%.5f|%.5f|%.5f|%.3f|%.3f|%.3f|%.2f|%.2f|%.2f|%s|%d|%.3f|%.3f|%.3f",
      id, cx, cy, cz, qx, qy, qz, qw, hx, hy, hz, vx, vy, vz, carFor(veh, id).model, has, dgx, dgy, dgz))
  end
end

local function closeSocket()
  if udp then pcall(udp.close, udp) end
  udp = nil
end

local function start()
  if running then return true end
  local u = socket.udp()
  local ok, err = u:setsockname("127.0.0.1", cfg.listenPort)
  if not ok then
    log("E", logTag, "could not bind UDP port " .. tostring(cfg.listenPort) .. ": " .. tostring(err))
    pcall(u.close, u)
    return false
  end
  u:settimeout(0)
  udp = u
  running = true
  log("I", logTag, "listening on 127.0.0.1:" .. cfg.listenPort .. ", sending to " .. cfg.host .. ":" .. cfg.gtaPort)
  return true
end

local function stop()
  engaged = false
  running = false
  closeSocket()
  destroyBody()
  ped.fresh = false
  log("I", logTag, "stopped")
end

local function align()
  needOffset = true
  return true
end

local function here()
  if not ped.fresh then log("W", logTag, "here(): no GTA data") return false end
  local c = core_camera.getPosition()
  local ok, d = pcall(castRayStatic, vec3(c.x, c.y, c.z), vec3(0, 0, -1), 2000)
  local gz = (ok and d and d < 2000) and (c.z - d) or c.z
  local rx, ry = rotZ(ped.gx, ped.gy, yawRad)
  cfg.ox, cfg.oy = c.x - rx, c.y - ry
  cfg.oz = gz - (ped.gz - 1.0)
  lastGround = gz
  saveConfig()
  log("I", logTag, string.format("character moved to %.1f, %.1f, %.1f", c.x, c.y, gz))
  return true
end

local manualOff, autoAt = false, nil
local function engage()
  manualOff = false
  if not running and not start() then return false end
  if not getWalker() then
    local pv = getPlayerVehicle(0)
    local p = pv and pv:getPosition() or core_camera.getPosition()
    ensureWalker(p.x, p.y, p.z)
  end
  engaged = true
  S.restDumped = false
  lastGround = nil
  waters = nil
  needOffset = true
  S.offsetAt = socket.gettime() + 1.0
  send(string.format("M|platform|%d", cfg.usePlatform and 1 or 0))
  log("I", logTag, "engaged")
  return true
end

local function disengage()
  engaged = false
  manualOff = true
  local u = getWalker()
  if u and lastGround then
    local p = u:getPosition()
    moveVeh(u, vec3(p.x, p.y, lastGround + 0.3))
    pcall(u.setMeshAlpha, u, 1, "", false)
  end
  destroyBody()
  log("I", logTag, "disengaged")
end

local function set(key, value)
  if cfg[key] == nil then
    log("W", logTag, "unknown setting " .. tostring(key))
    return false
  end
  cfg[key] = value
  applyConfig()
  saveConfig()
  if key == "usePlatform" and engaged then
    send(string.format("M|platform|%d", value and 1 or 0))
  end
  return true
end

local function status()
  local s = string.format("running=%s engaged=%s gtaData=%s offset=(%.1f,%.1f,%.1f) yaw=%.1f",
    tostring(running), tostring(engaged), tostring(ped.fresh), cfg.ox, cfg.oy, cfg.oz, cfg.yawDeg)
  log("I", logTag, s)
  return s
end

local function holdTab(on)
  if on == S.tabHeld or not core_input_actionFilter then return end
  S.tabHeld = on
  core_input_actionFilter.setGroup("gtaBridgeOnFoot", { "switch_next_vehicle", "switch_previous_vehicle", "switch_next_vehicle_multiseat", "toggle_minimap" })
  core_input_actionFilter.addAction(0, "gtaBridgeOnFoot", on)
end

local WHEEL = "/root/gtaBridge/weapons/"
local wheel, tabWas

local function wheelPick(items, dx, dy)
  if dx * dx + dy * dy < 0.07 * 0.07 then return end
  local a = (0.5 - math.atan2(dy, dx) / (2 * math.pi)) % 1
  for i, it in ipairs(items) do
    if it.position and it.size then
      local d = math.abs(a - it.position % 1)
      if math.min(d, 1 - d) <= it.size / 2 then return i end
    end
  end
end

local function pointer()
  local c = scenetree.findObject("Canvas")
  local p = c and c:getCursorPos()
  if not p or (p.x == -1 and p.y == -1) then return end
  local w, h = c:getWindowClientSizeXY()
  local ox, oy = c:clientToScreenXY(Point2I(0, 0))
  if not (w and h and ox and oy) or w <= 0 or h <= 0 then return end
  return (p.x - ox) / w, (p.y - oy) / h, w / h
end

local function updateWheel(tab)
  local qa = core_quickAccess
  if not qa then return end
  local now = socket.gettime()
  local inHand = WEAPON[ped.weapon]
  for i = 2, #LOADOUT do if LOADOUT[i] == inHand then S.lastGun = i - 1 end end
  if tab and not tabWas then S.tabT = now end
  if tab and not wheel and now - S.tabT >= cfg.wheelHold then
    qa.addEntry({ level = WHEEL, uniqueID = "gtaBridgeWeapons", generator = function(entries)
      for i, w in ipairs(LOADOUT) do
        table.insert(entries, { title = w.name, icon = w.icon, startSlot = w.slot, endSlot = w.slot, ignoreAsRecentAction = true,
          color = ped.weapon == w.hash and "var(--bng-orange)" or nil,
          onSelect = function() send("M|weapon|" .. (i - 1)) return { "hide" } end })
      end
    end })
    qa.setSlowMoFactor(cfg.wheelSlowMo)
    qa.setEnabled(true, WHEEL)
    wheel = {}
  elseif wheel then
    if qa.isEnabled() then wheel.seen = true elseif wheel.seen then wheel.shut = true end
    if not wheel.x then wheel.x, wheel.y = pointer() end
    if not tab then
      local ui, x, y, aspect = qa.getUiData(), pointer()
      if not wheel.shut and qa.isEnabled() and ui and ui.currentLevel == WHEEL and ui.items and x and wheel.x
        and math.abs(x - wheel.x) + math.abs(y - wheel.y) > 0.01 then
        local i = wheelPick(ui.items, (x - 0.5) * aspect, 0.55 - y)
        if i then qa.selectItem(i, true, 1) end
      end
      if not wheel.shut then qa.setEnabled(false) end
      qa.resetSlowMoFactor()
      wheel = nil
    end
  elseif tabWas and not tab then
    send("M|weapon|" .. (inHand == LOADOUT[1] and S.lastGun or 0))
  end
  tabWas = tab
  local s = (wheel and not wheel.shut) and cfg.wheelSlowMo or 1
  if s ~= slow then slow = s; send(string.format("M|slow|%.2f", s)) end
end

local BULLET = "extensions.load('gtaBullet') gtaBullet.hit(%f, %f, %f, %f, %f, %f, %f, %f, %d)"
local holes, pending, shotSeq = {}, {}, 0

local HOLE_VARIANTS = 16
local holeMats = false

local function holeSprite(h)
  if holeMats == false then
    holeMats = pcall(loadJsonMaterialsFile, "/art/shapes/gtaBridge/holes.materials.json")
  end
  if not holeMats then return end
  local ok, o = pcall(newObj, string.format("/art/shapes/gtaBridge/gtaHole%d.dae", math.random(0, HOLE_VARIANTS - 1)), "gtaHole" .. tostring(os.clock()):gsub("%.", "_") .. math.random(1, 1e6))
  if ok and o then h.obj, h.roll = o, 0 else holeMats = nil end
end

local function dropHole(h)
  if h.obj then pcall(h.obj.delete, h.obj) h.obj = nil end
end

local HOLE_LIFE = 60

local function sweepHoleObjects()
  for _, name in ipairs(scenetree.findClassObjects("TSStatic") or {}) do
    if tostring(name):find("^gtaHole") then
      local o = scenetree.findObject(name)
      if o then pcall(o.delete, o) end
    end
  end
end

local function addHole(h)
  h.born = socket.gettime()
  holeSprite(h)
  holes[#holes + 1] = h
  if #holes > cfg.bulletHoles then dropHole(table.remove(holes, 1)) end
end

local function hitStatic(o, d, range)
  local ok, t = pcall(castRayStatic, o, d, range)
  if not ok or not t or t >= range then return end
  local r = d:cross(vec3(0, 0, 1))
  if r:length() < 1e-3 then r = vec3(1, 0, 0) end
  r = r:normalized() * 0.01
  local u = r:cross(d)
  local n = -d
  local ok1, t1 = pcall(castRayStatic, o + r, d, range)
  local ok2, t2 = pcall(castRayStatic, o + u, d, range)
  if ok1 and ok2 and t1 and t2 and math.abs(t1 - t) < 0.3 and math.abs(t2 - t) < 0.3 then
    n = (r + d * (t1 - t)):cross(u + d * (t2 - t)):normalized()
  end
  return t, n
end

local function fireBullet(o, d)
  local t, n = hitStatic(o, d, cfg.bulletRange)
  local wall = t and { p = o + d * t, n = n } or nil
  local reach, waiting = t or cfg.bulletRange, 0
  shotSeq = shotSeq + 1
  pending[shotSeq - 100] = nil
  for _, veh in ipairs(getAllVehicles()) do
    local id, jb = veh:getID(), veh:getJBeamFilename()
    if jb ~= "unicycle" and jb ~= "gta_body" and jb ~= "gta_puppet" and veh:getActive() and be:getObjectOOBBIsInitialized(id) then
      local near, far = intersectsRay_OBB(o, d, vec3(be:getObjectOOBBCenterXYZ(id)), vec3(be:getObjectOOBBHalfAxisXYZ(id, 0)),
        vec3(be:getObjectOOBBHalfAxisXYZ(id, 1)), vec3(be:getObjectOOBBHalfAxisXYZ(id, 2)))
      if near < reach and far > 0 then
        waiting = waiting + 1
        veh:queueLuaCommand(string.format(BULLET, o.x, o.y, o.z, d.x, d.y, d.z, reach, cfg.bulletPush * 2000, shotSeq))
      end
    end
  end
  if waiting > 0 then pending[shotSeq] = { wall = wall, waiting = waiting }
  elseif wall then addHole(wall) end
  return o + d * reach
end

local function bulletReply(shot, vehId, a, b, c, u, v)
  local s = pending[shot]
  if not s then return end
  s.waiting = s.waiting - 1
  if vehId then
    s.hit = true
    if a then addHole({ veh = vehId, a = a, b = b, c = c, u = u, v = v }) end
  end
  if s.waiting <= 0 then
    if not s.hit and s.wall then addHole(s.wall) end
    pending[shot] = nil
  end
end

local function holeAt(h)
  if not h.veh then return h.p, h.n, 0.006 end
  local veh = be:getObjectByID(h.veh)
  if not veh then return end
  local a, b, c = vec3(veh:getNodePosition(h.a)), vec3(veh:getNodePosition(h.b)), vec3(veh:getNodePosition(h.c))
  return vec3(veh:getPosition()) + a * h.u + b * h.v + c * (1 - h.u - h.v), (c - a):cross(b - c):normalized(), 0.03
end

local tracers = {}

local function muzzlePoint()
  if not ped.muz then return nil end
  local ex = slow * math.max(0, math.min(0.08, socket.gettime() - ped.t))
  return vec3(gtaToBeam(ped.muz[1] + (ped.vx or 0) * ex, ped.muz[2] + (ped.vy or 0) * ex, ped.muz[3]))
end

local function muzzleDir()
  if not ped.muzd then return nil end
  local d = vec3(dirToBeam(ped.muzd[1], ped.muzd[2], ped.muzd[3]))
  if d:length() < 0.1 then return nil end
  return d:normalized()
end

local function drawHoles()
  local eye = core_camera.getPosition()
  eye = eye and vec3(eye)
  local col = ColorF(0.02, 0.02, 0.02, 1)
  local nowC = socket.gettime()
  for i = #holes, 1, -1 do
    if nowC - (holes[i].born or nowC) > HOLE_LIFE then dropHole(table.remove(holes, i)) end
  end
  for _, h in ipairs(holes) do
    local p, n, under = holeAt(h)
    if p then
      local to = eye and eye - p
      if to and to:length() > under * 2 then p = p + to * (under / to:length()) end
      if h.obj then
        local ref = math.abs(n.z) < 0.9 and vec3(0, 0, 1) or vec3(1, 0, 0)
        local rt = n:cross(ref):normalized()
        local up2 = n:cross(rt)
        local rr = rt * math.cos(h.roll) + up2 * math.sin(h.roll)
        local f = n:cross(rr)
        local qx, qy, qz, qw = quatFromBasis(rr.x, rr.y, rr.z, f.x, f.y, f.z, n.x, n.y, n.z)
        local sz = cfg.holeSize * 3.2
        place(h.obj, p.x + n.x * 0.003, p.y + n.y * 0.003, p.z + n.z * 0.003, qx, qy, qz, qw, sz, sz, sz)
      else
        debugDrawer:drawCylinder(p - n * 0.0005, p + n * 0.0005, cfg.holeSize, col)
      end
    end
  end
  local now = socket.gettime()
  for i = #tracers, 1, -1 do
    local t = tracers[i]
    local s1 = (now - t.t) * 160
    local s0 = math.max(0, s1 - 4)
    if not (t.len == t.len) or #tracers > 200 or s0 >= t.len then table.remove(tracers, i)
    else debugDrawer:drawCylinder(t.a + t.d * s0, t.a + t.d * math.min(s1, t.len), 0.008, ColorF(1, 0.95, 0.8, 0.6)) end
  end
  local fl = ped.flags or 0
  if engaged and cfg.tracer > 0 and (math.floor(fl / 128) % 2 == 1 or math.floor(fl / 256) % 2 == 1) then
    local cp, q = core_camera.getPosition(), core_camera.getQuat()
    if cp and q then
      cp = vec3(cp)
      local f = quat(q) * vec3(0, 1, 0)
      local ok, d = pcall(castRayStatic, cp, f, 60)
      d = (ok and d and d < 60) and d or 60
      debugDrawer:drawSphere(cp + f * d, math.max(d, 1) * 0.0022, ColorF(1, 1, 1, 0.9))
    end
  end
end

local function shoot(n, hand, mz, md)
  local cp, q = core_camera.getPosition(), core_camera.getQuat()
  if not (cp and q) then return end
  cp = vec3(cp)
  local f = quat(q) * vec3(0, 1, 0)
  local o = cp + f * math.max(0, (vec3(walkerFeet.x, walkerFeet.y, walkerFeet.z + 1.4) - cp):dot(f))
  local pellets = WEAPON[ped.weapon] and WEAPON[ped.weapon].pellets or 1
  for _ = 1, n * pellets do
    local d = pellets == 1 and f or (f + vec3(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 0.07):normalized()
    local to = fireBullet(o, d)
    if cfg.tracer > 0 then
      if mz and md then
        tracers[#tracers + 1] = { a = mz, d = (to - mz):normalized(), len = (to - mz):length(), t = socket.gettime() }
      elseif hand then
        local dir = (to - hand):normalized()
        local a = hand + dir * 0.3 + vec3(0, 0, 0.1)
        tracers[#tracers + 1] = { a = a, d = (to - a):normalized(), len = (to - a):length(), t = socket.gettime() }
      end
    end
  end
end

local function guard(f, ...)
  local ok, err = pcall(f, ...)
  if not ok and err ~= S.lastErr then
    S.lastErr = err
    log("E", logTag, tostring(err))
  end
end

local riding = false

local entering
local origToggle
local function doorCmd(veh, phase, side)
  veh:queueLuaCommand(string.format([[
    local phase = "%s"
    local air = controller.getController("doors")
    if air and air.setBeamGroupsValveState then
      air.setBeamGroupsValveState({ "frontDoors", "rearDoors" }, phase == "close" and 1 or -1)
      if phase ~= "close" then
        local nm = beamstate.nodeNameMap
        for _, p in ipairs({ { "fdb5r", "fdb1l" }, { "fdb6r", "fdb2l" }, { "fdb5l", "fdb1r" }, { "fdb6l", "fdb2r" } }) do
          local a, b = nm[ p[1] ], nm[ p[2] ]
          if a and b then obj:applyForceTime(b, a, %d, 0.3) end
        end
      end
      phase = "bus"
    end
    local want, found, seen = { "doorf%scoupler", "door%scoupler" }, nil, {}
    for _, c in pairs(controller.getControllersByType("advancedCouplerControl") or {}) do
      local n = string.lower(tostring(c.name or "")):gsub("[^%%a]", "")
      seen[#seen + 1] = tostring(c.name)
      for i, w in ipairs(want) do
        if n == w and (not found or i < found.i) then found = { c = c, i = i } end
      end
    end
    if phase == "bus" then
    elseif found then
      local n1, n2
      pcall(function()
        local r = tableFromHeaderTable(v.data[found.c.name].couplerNodes)[1]
        local c2 = type(r.cid2) == "table" and r.cid2[1] or r.cid2
        n1 = beamstate.nodeNameMap[r.forceCid1 or r.cid1]
        n2 = beamstate.nodeNameMap[r.forceCid2 or c2]
      end)
      if phase == "open" then found.c.detachGroup() elseif phase == "close" then found.c.tryAttachGroupImpulse() end
      if n1 and n2 then obj:applyForceTime(n2, n1, %d, %.2f) end
    else
      log("W", "gtaBridge", "no front door latch on that side among: " .. table.concat(seen, ", "))
    end
  ]], phase, cfg.busDoorForce, side, side,
    phase == "open" and -cfg.doorPush or phase == "hold" and -cfg.doorHold or cfg.doorPull,
    phase == "open" and cfg.doorPushTime or phase == "hold" and 0.3 or cfg.doorPullTime))
end
local function carAtHand()
  if not walkerHave then return nil end
  local p = vec3(walkerFeet.x, walkerFeet.y, walkerFeet.z + 0.9)
  local best, bestD = nil, 1.5
  for _, veh in ipairs(getAllVehicles()) do
    local id = veh:getID()
    local jb = veh:getJBeamFilename()
    if jb ~= "unicycle" and jb ~= "gta_body" and veh:getActive() and be:getObjectOOBBIsInitialized(id) and not carFor(veh, id).skip then
      local d = p - vec3(be:getObjectOOBBCenterXYZ(id))
      for a = 0, 2 do
        local ax = vec3(be:getObjectOOBBHalfAxisXYZ(id, a))
        local len = ax:length()
        if len > 1e-4 then
          local u = ax / len
          d = d - u * math.max(-len, math.min(len, d:dot(u)))
        end
      end
      local dist = d:length()
      if dist < bestD then best, bestD = veh, dist end
    end
  end
  return best
end
local function takeOver(veh)
  local id = veh:getID()
  pcall(function() if extensions.gameplay_traffic then extensions.gameplay_traffic.removeTraffic(id, true) end end)
  pcall(function() if extensions.gameplay_parking then extensions.gameplay_parking.removeVehicle(id) end end)
  pcall(extensions.gameplay_walk.removeVehicleFromBlacklist, id)
  veh.playerUsable = true
end

local function bridgeToggle()
  local w = extensions.gameplay_walk
  local now = socket.gettime()
  if entering or now - S.toggleT < 0.7 then return end
  S.toggleT = now
  if engaged and not riding and not settled() then return end
  local veh = engaged and not riding and carAtHand() or (w and w.getVehicleInFront and w.getVehicleInFront())
  if veh and veh:getJBeamFilename() == "gta_body" then return end
  if engaged and cfg.enterAnim and cfg.cars and not riding and veh and ped.fresh and w.isWalking() then
    takeOver(veh)
    entering = { id = veh:getID(), t = socket.gettime() }
    send(string.format("E|%d", entering.id))
    return
  end
  if engaged and riding and w and w.setWalkingMode then return w.setWalkingMode(true, nil, nil, true) end
  if origToggle then return origToggle() end
end
local function patchWalk()
  local w = extensions.gameplay_walk
  if w and w.toggleWalkingMode ~= bridgeToggle then
    origToggle = w.toggleWalkingMode
    w.toggleWalkingMode = bridgeToggle
  end
end
local function unpatchWalk()
  local w = extensions.gameplay_walk
  if w and origToggle and w.toggleWalkingMode == bridgeToggle then w.toggleWalkingMode = origToggle end
end
local function getIn(veh)
  pcall(function()
    veh:queueLuaCommand('ai.setMode("disabled")')
    extensions.hook("onBeforeWalkingModeToggled", false, veh:getID())
    extensions.gameplay_walk.getInVehicle(veh)
  end)
end
local function updateEntering()
  if not entering then return end
  local veh = getObjectByID(entering.id)
  if not veh then entering = nil return end
  local now = socket.gettime()
  local fl = ped.flags or 0
  local inVeh = math.floor(fl / 2048) % 2 == 1
  local doorOpen = math.floor(fl / 16384) % 2 == 1
  if math.floor(fl / 32768) % 2 == 1 then entering.active = true end
  if doorOpen and not entering.door then
    entering.door = true
    entering.holdT = now + cfg.doorPushTime
    entering.side = math.floor(fl / 131072) % 2 == 1 and "r" or "l"
    log("I", logTag, "GTA opened the " .. (entering.side == "r" and "right" or "left") .. " door: opening BeamNG's")
    doorCmd(veh, "open", entering.side)
  end
  if entering.door and not entering.closed and now >= entering.holdT then
    entering.holdT = now + 0.25
    doorCmd(veh, "hold", entering.side)
  end
  if inVeh and not entering.seatedAt then entering.seatedAt = now end
  if entering.seatedAt and not entering.logged and now - entering.seatedAt > 1.0 and ped.sk and #ped.sk >= 54 then
    entering.logged = true
    pcall(function()
      local dn = core_camera.getDriverData(veh)
      local dp = veh:getPosition() + veh:getNodePosition(dn)
      local hx, hy, hz = gtaToBeam(ped.sk[10], ped.sk[11], ped.sk[12])
      log("I", logTag, string.format("seated: BeamNG driver eyes (%.2f, %.2f, %.2f), GTA head (%.2f, %.2f, %.2f), ground %.2f",
        dp.x, dp.y, dp.z, hx, hy, hz, walkerFeet.z))
    end)
  end
  if entering.seatedAt then
    if entering.door and not entering.closed and now - entering.seatedAt > 0.3 then
      entering.closed = true
      doorCmd(veh, "close", entering.side)
    end
    if now - entering.seatedAt > 1.3 then entering = nil getIn(veh) end
  elseif not entering.active and now - entering.t > 1.0 then
    entering = nil
    getIn(veh)
  elseif entering.active and math.floor(fl / 32768) % 2 == 0 and now - entering.t > 1.0 then
    if entering.door then doorCmd(veh, "close", entering.side) end
    entering = nil
  end
end
local OB = { built = false, building = false, cells = {}, list = {}, sendT = 0, CELL = 8 }
function OB.sc3(v)
  if type(v) == "number" then return v, v, v end
  if v then return v.x or 1, v.y or 1, v.z or 1 end
  return 1, 1, 1
end
function OB.kind(shape, sx, sy, sz)
  local s = string.lower(shape or "")
  local long, short = math.max(sx, sy), math.min(sx, sy)
  if sz < 0.3 then return nil end
  for _, w in ipairs({ "bush", "shrub", "grass", "flower", "plant", "decal", "rock", "cliff", "terrain", "road", "curb", "kerb" }) do
    if s:find(w, 1, true) then return nil end
  end
  for _, w in ipairs({ "tree", "palm", "pine", "oak", "birch", "cypress", "trunk" }) do
    if s:find(w, 1, true) then return sz > 2 and 1 or nil end
  end
  if long > 12 then return nil end
  for _, w in ipairs({ "fence", "chainlink", "railing", "guardrail", "rail_", "barrier" }) do
    if s:find(w, 1, true) and short < 0.7 and long > 0.9 then return 2 end
  end
  for _, w in ipairs({ "mailbox", "postbox", "letterbox" }) do
    if s:find(w, 1, true) then return 3 end
  end
  for _, w in ipairs({ "elec", "transformer", "utilitybox", "junction", "breaker", "meter" }) do
    if s:find(w, 1, true) and long < 4 then return 4 end
  end
  if long < 1.2 and sz > 2 then return 1 end
  if long < 3.6 and sz < 4 then return 5 end
  return nil
end
function OB.put(o)
  local cx, cy = math.floor(o.c.x / OB.CELL), math.floor(o.c.y / OB.CELL)
  local key = cx .. ":" .. cy
  local cell = OB.cells[key]
  if not cell then cell = {} OB.cells[key] = cell end
  cell[#cell + 1] = o
  OB.list[#OB.list + 1] = o
  o.id = #OB.list
end
function OB.axisOf(obj)
  local ok, m = pcall(function() return obj:getTransform() end)
  if ok and m then
    local ok2, c = pcall(function() return m:getColumn(0) end)
    if ok2 and c and (c.x ~= 0 or c.y ~= 0) then
      OB.axisMode = "transform"
      local l = math.sqrt(c.x * c.x + c.y * c.y)
      return c.x / l, c.y / l
    end
  end
  return 1, 0
end
function OB.addObj(shape, pos, obj, box, sx3, sy3, sz3)
  if not box then return end
  local mn, mx = box.minExtents, box.maxExtents
  local sx, sy, sz = math.abs(mx.x - mn.x) * sx3, math.abs(mx.y - mn.y) * sy3, math.abs(mx.z - mn.z) * sz3
  local k = OB.kind(shape, sx, sy, sz)
  if not k then
    OB.skipped = (OB.skipped or 0) + 1
    return
  end
  local axx, axy = OB.axisOf(obj)
  local ayx, ayy = -axy, axx
  local lcx, lcy = (mn.x + mx.x) * 0.5 * sx3, (mn.y + mx.y) * 0.5 * sy3
  local c = vec3(pos.x + axx * lcx + ayx * lcy, pos.y + axy * lcx + ayy * lcy, pos.z + mn.z * sz3)
  if k == 1 then c = vec3(pos.x, pos.y, pos.z) end
  OB.put({ kind = k, c = c, axx = axx, axy = axy, sx = sx, sy = sy, sz = sz, shape = shape })
  OB.kinds = OB.kinds or {}
  OB.kinds[k] = (OB.kinds[k] or 0) + 1
end
function OB.build()
  if OB.built then return end
  if not OB.building then
    OB.building = true
    OB.cells, OB.list, OB.kinds, OB.skipped = {}, {}, {}, 0
    OB.t0 = socket.gettime()
    OB.fi = 1
    OB.shapeOf, OB.boxOf = {}, {}
    local ok, all = pcall(function()
      local f = core_forest and core_forest.getForestObject()
      local data = f and f:getData()
      return data and data:getItems()
    end)
    OB.items = ok and all or {}
    OB.statics = {}
    pcall(function()
      if getObjectsByClass then
        for _, o in ipairs(getObjectsByClass("TSStatic") or {}) do OB.statics[#OB.statics + 1] = o end
      end
    end)
    if #OB.statics == 0 then
      pcall(function()
        for _, name in ipairs(scenetree.findClassObjects("TSStatic") or {}) do
          local o = scenetree.findObject(name)
          if o then OB.statics[#OB.statics + 1] = o end
        end
      end)
    end
    return
  end
  local items = OB.items
  local stop = math.min(#items, OB.fi + 4000)
  for i = OB.fi, stop do
    local it = items[i]
    pcall(function()
      local d = it:getData()
      local shape = OB.shapeOf[d]
      if shape == nil then shape = d:getShapeFile() or "" OB.shapeOf[d] = shape end
      local box = OB.boxOf[shape]
      if box == nil then box = it:getObjBox() or false OB.boxOf[shape] = box end
      if box then OB.addObj(shape, it:getPosition(), it, box, OB.sc3(it:getScale())) end
    end)
  end
  OB.fi = stop + 1
  if OB.fi <= #items then return end
  for _, o in ipairs(OB.statics) do
    pcall(function()
      local shape = o.shapeName or ""
      if shape == "" then pcall(function() shape = o:getField("shapeName", 0) or "" end) end
      OB.addObj(shape, o:getPosition(), o, o:getObjBox(), OB.sc3(o:getScale()))
    end)
  end
  OB.items, OB.statics = nil, nil
  OB.built, OB.building = true, false
  local k = OB.kinds or {}
  log("I", logTag, string.format("objects: %d kept (poles %d, fences %d, mailboxes %d, electrical %d, boxes %d), %d skipped, axes from %s, %.1f s",
    #OB.list, k[1] or 0, k[2] or 0, k[3] or 0, k[4] or 0, k[5] or 0, OB.skipped or 0, OB.axisMode or "nothing", socket.gettime() - OB.t0))
end
function OB.near(p, r)
  local out = {}
  if not OB.built then return out end
  local c0x, c0y = math.floor((p.x - r) / OB.CELL), math.floor((p.y - r) / OB.CELL)
  local c1x, c1y = math.floor((p.x + r) / OB.CELL), math.floor((p.y + r) / OB.CELL)
  for cx = c0x, c1x do
    for cy = c0y, c1y do
      local cell = OB.cells[cx .. ":" .. cy]
      if cell then
        for _, o in ipairs(cell) do
          local dx, dy = o.c.x - p.x, o.c.y - p.y
          if dx * dx + dy * dy < r * r then out[#out + 1] = o end
        end
      end
    end
  end
  return out
end
function OB.inside(list, x, y, z)
  local now = socket.gettime()
  for _, o in ipairs(list) do
    if z >= o.c.z - 0.05 and z <= o.c.z + o.sz + 0.05 and (o.kind == 1 or now - (o.sent or -math.huge) < 0.75) then
      local dx, dy = x - o.c.x, y - o.c.y
      if o.kind == 1 then
        if dx * dx + dy * dy < 0.6 * 0.6 then return true end
      else
        local u, v = dx * o.axx + dy * o.axy, -dx * o.axy + dy * o.axx
        if math.abs(u) < o.sx * 0.5 + 0.3 and math.abs(v) < o.sy * 0.5 + 0.3 then return true end
      end
    end
  end
  return false
end
function OB.tick()
  if not (cfg.walls and walkerHave) then return end
  if not OB.built then OB.build() return end
  local now = socket.gettime()
  if now - OB.sendT < 0.1 then return end
  OB.sendT = now
  local list = OB.near(walkerFeet, 14)
  table.sort(list, function(a, b)
    return (a.c.x - walkerFeet.x) ^ 2 + (a.c.y - walkerFeet.y) ^ 2 < (b.c.x - walkerFeet.x) ^ 2 + (b.c.y - walkerFeet.y) ^ 2
  end)
  local parts, n = {}, 0
  for _, o in ipairs(list) do
    if o.kind ~= 1 and n < 16 then
      n = n + 1
      o.sent = now
      local gx, gy, gz = beamToGta(o.c.x, o.c.y, o.c.z)
      local tx, ty = dirToGta(o.axx, o.axy, 0)
      parts[#parts + 1] = string.format("%d|%d|%.2f|%.2f|%.2f|%.3f|%.3f|%.2f|%.2f|%.2f", o.id, o.kind, gx, gy, gz, tx, ty, o.sx, o.sy, o.sz)
    end
  end
  if n > 0 then send("J|" .. n .. "|" .. table.concat(parts, "|")) end
end

local SOLID = 9
local function wallsNearby()
  if not (cfg.walls and settled() and ped.fresh and lastGround and walkerHave) then return end
  local now = socket.gettime()
  if now - S.obsT < 0.05 then return end
  S.obsT = now
  local g = walkerFeet.z
  local o = vec3(walkerFeet.x, walkerFeet.y, g)
  local N, R = 48, 3.0
  local down = vec3(0, 0, -1)
  local function ahead(z, dir, range)
    local ok, d = pcall(castRayStatic, vec3(o.x, o.y, g + z), dir, range)
    if ok and d and d < range then return d end
  end
  local function topAt(x, y, from)
    local ok, d = pcall(castRayStatic, vec3(x, y, g + from), down, from)
    if ok and d and d < from then return from - d end
  end
  local function topAround(p, dir, t, from)
    local vals = {}
    for _, s in ipairs({ -0.3, 0, 0.3 }) do
      local m = 0
      for _, dep in ipairs(s == 0 and { 0.03, 0.12, 0.3 } or { 0.12 }) do
        local q = p + dir * dep + t * s
        local h = topAt(q.x, q.y, from)
        if h and h > 0.15 and h > m then m = h end
      end
      vals[#vals + 1] = m
    end
    table.sort(vals)
    return vals[2] > 0 and vals[2] or nil
  end
  local pts = {}
  local nearO = OB.near(o, R + 3)
  for i = 1, N do
    local a = (i - 1) * 2 * math.pi / N
    local dir = vec3(math.cos(a), math.sin(a), 0)
    for _, z in ipairs({ 0.35, 1.1 }) do
      local d = ahead(z, dir, R)
      if d and d > 0.1 and not OB.inside(nearO, o.x + dir.x * d, o.y + dir.y * d, g + z) then pts[#pts + 1] = { x = o.x + dir.x * d, y = o.y + dir.y * d } end
    end
  end
  local function fit(idx)
    local cx, cy = 0, 0
    for _, k in ipairs(idx) do cx, cy = cx + pts[k].x, cy + pts[k].y end
    cx, cy = cx / #idx, cy / #idx
    local sxx, syy, sxy = 0, 0, 0
    for _, k in ipairs(idx) do
      local dx, dy = pts[k].x - cx, pts[k].y - cy
      sxx, syy, sxy = sxx + dx * dx, syy + dy * dy, sxy + dx * dy
    end
    local an = 0.5 * math.atan2(2 * sxy, sxx - syy)
    return cx, cy, math.cos(an), math.sin(an)
  end
  local function near(cx, cy, tx, ty, tol)
    local idx = {}
    for k = 1, #pts do
      if not pts[k].used and not pts[k].short and math.abs(tx * (pts[k].y - cy) - ty * (pts[k].x - cx)) < tol then idx[#idx + 1] = k end
    end
    return idx
  end
  local walls = {}
  for _ = 1, 8 do
    local bestIdx
    for a = 1, #pts do
      if not pts[a].used and not pts[a].short then
        for b = a + 1, math.min(#pts, a + 4) do
          if not pts[b].used and not pts[b].short then
            local dx, dy = pts[b].x - pts[a].x, pts[b].y - pts[a].y
            local L = math.sqrt(dx * dx + dy * dy)
            if L > 0.05 and L < 1.5 then
              local idx = near(pts[a].x, pts[a].y, dx / L, dy / L, 0.08)
              if not bestIdx or #idx > #bestIdx then bestIdx = idx end
            end
          end
        end
      end
    end
    if not bestIdx or #bestIdx < 4 then break end
    local cx, cy, tx, ty = fit(bestIdx)
    local idx = near(cx, cy, tx, ty, 0.12)
    if #idx < 4 then idx = bestIdx else cx, cy, tx, ty = fit(idx) end
    local ss = {}
    for _, k in ipairs(idx) do
      pts[k].used = true
      ss[#ss + 1] = { s = (pts[k].x - cx) * tx + (pts[k].y - cy) * ty, k = k }
    end
    table.sort(ss, function(p, q) return p.s < q.s end)
    local s0 = 1
    local sp = (o.x - cx) * tx + (o.y - cy) * ty
    for k = 2, #ss + 1 do
      if k > #ss or ss[k].s - ss[k - 1].s > 0.8 then
        local lo, hi = ss[s0].s, ss[k - 1].s
        if k - s0 >= 3 and hi - lo >= 0.6 then
          local sc = math.max(lo, math.min(hi, sp))
          local fx, fy = cx + tx * sc, cy + ty * sc
          local nx, ny = -ty, tx
          local off = (fx - o.x) * nx + (fy - o.y) * ny
          if off < 0 then nx, ny, off = -nx, -ny, -off end
          local function opened(sv)
            local qx, qy = cx + tx * sv - o.x, cy + ty * sv - o.y
            local ql = math.sqrt(qx * qx + qy * qy)
            if ql < 0.2 or ql > R - 0.2 then return false end
            local hd = ahead(1.1, vec3(qx / ql, qy / ql, 0), ql + 0.5)
            return not hd or hd > ql + 0.3
          end
          local eLo, eHi = -999, 999
          if opened(lo - 0.6) then eLo = lo - sc end
          if opened(hi + 0.6) then eHi = hi - sc end
          walls[#walls + 1] = { fx = fx, fy = fy, tx = tx, ty = ty, nx = nx, ny = ny, off = off, eLo = eLo, eHi = eHi, d = math.sqrt((fx - o.x) ^ 2 + (fy - o.y) ^ 2) }
        else
          for j = s0, k - 1 do pts[ss[j].k].used = false; pts[ss[j].k].short = true end
        end
        s0 = k
      end
    end
  end
  table.sort(walls, function(p, q) return p.off < q.off end)
  local keep = {}
  for _, w in ipairs(walls) do
    local hidden
    for _, kw in ipairs(keep) do
      if math.abs(kw.tx * w.ty - kw.ty * w.tx) < 0.17 and kw.nx * w.nx + kw.ny * w.ny > 0 and w.off - kw.off < 0.45
        and math.abs((w.fx - kw.fx) * kw.tx + (w.fy - kw.fy) * kw.ty) < 3 then hidden = true break end
    end
    if not hidden then keep[#keep + 1] = w end
  end
  local out = {}
  for _, w in ipairs(keep) do
    local f = vec3(w.fx, w.fy, g)
    local d = w.d
    if d > 0.1 and d < R + 0.5 then
      local dir = vec3(w.fx - o.x, w.fy - o.y, 0) * (1 / d)
      local t = vec3(w.tx, w.ty, 0)
      local top
      if not ahead(1.45, dir, d + 0.4) then
        top = topAround(f, dir, t, 1.45) or 1.0
        local behind = topAt(f.x + dir.x * 0.5, f.y + dir.y * 0.5, 1.45)
        if top < 0.45 or (top < 0.7 and behind and behind > top + 0.12) then top = nil end
      elseif not ahead(2.5, dir, d + 0.4) then
        top = topAround(f, dir, t, 2.5) or 2.0
        if top > 2.3 then top = SOLID end
      else
        top = SOLID
      end
      if top then
        local gx, gy, gz = beamToGta(f.x, f.y, g + top)
        local gtx, gty = dirToGta(w.tx, w.ty, 0)
        out[#out + 1] = { d = d, s = string.format("%.2f|%.2f|%.2f|%.3f|%.3f|%.2f|%.2f", gx, gy, gz, gtx, gty, w.eLo, w.eHi) }
      end
    end
  end
  local poles = {}
  for a = 1, #pts do
    local p = pts[a]
    if not p.used and not p.pole then
      local mx, my, n = 0, 0, 0
      local members = {}
      for k = 1, #pts do
        local q = pts[k]
        if not q.used and not q.pole and (q.x - p.x) ^ 2 + (q.y - p.y) ^ 2 < 0.36 then
          members[#members + 1] = q
          mx, my, n = mx + q.x, my + q.y, n + 1
        end
      end
      if n >= 2 then
        mx, my = mx / n, my / n
        local spread = 0
        for _, q in ipairs(members) do spread = math.max(spread, (q.x - mx) ^ 2 + (q.y - my) ^ 2) end
        if spread < 0.2 then
          for _, q in ipairs(members) do q.pole = true end
          local vx, vy = mx - o.x, my - o.y
          local vl = math.sqrt(vx * vx + vy * vy)
          if vl > 0.1 and ahead(2.5, vec3(vx / vl, vy / vl, 0), vl + 0.5) then
            local px, py = mx + vx / vl * 0.25, my + vy / vl * 0.25
            local gx, gy, gz = beamToGta(px, py, g)
            poles[#poles + 1] = string.format("%.2f|%.2f|%.2f", gx, gy, gz)
          end
        end
      end
    end
  end
  for _, ob in ipairs(nearO) do
    if ob.kind == 1 and #poles < 8 then
      local gx, gy, gz = beamToGta(ob.c.x, ob.c.y, ob.c.z)
      poles[#poles + 1] = string.format("%.2f|%.2f|%.2f", gx, gy, gz)
    end
  end
  if #poles > 0 then send("P|" .. math.min(#poles, 10) .. "|" .. table.concat(poles, "|", 1, math.min(#poles, 10))) end
  if #out == 0 then return end
  table.sort(out, function(x, y) return x.d < y.d end)
  local parts = {}
  for i = 1, math.min(#out, 8) do parts[i] = out[i].s end
  send("O|" .. #parts .. "|" .. table.concat(parts, "|"))
end

local BODY_PTS = { 1, 2, 3, 4, 6, 7, 8, 10, 11, 12, 14, 15, 17, 18 }
local function carMovingNear(c)
  for _, veh in ipairs(getAllVehicles()) do
    local jb = veh:getJBeamFilename()
    if jb ~= "unicycle" and jb ~= "gta_body" and veh:getActive() and veh:getPosition():distance(c) < cfg.bodyNear
      and vec3(veh:getVelocity()):length() > cfg.bodySpeed then
      return true
    end
  end
  return false
end
local function updateBody()
  if not cfg.bodyCollide then return end
  local fl = ped.flags or 0
  local now = socket.gettime()
  local inCar = entering or math.floor(fl / 2048) % 2 == 1 or math.floor(fl / 32768) % 2 == 1
  local pts = not inCar and now > S.bodyHoldT and bodyPoints() or nil
  if pts and bodyLoaded then
    if carMovingNear(pts[1]) then S.bodyWantT = now end
    if now - S.bodyWantT > 1.5 then pts = nil end
  end
  local v = bodyVeh()
  if not v then
    if bodySpawnT or not pts then return end
    bodySpawnT = socket.gettime()
    local ok, res = pcall(function()
      local o = sanitizeVehicleSpawnOptions("gta_body", { vehicleName = "gtaBody", autoEnterVehicle = false })
      o.pos, o.rot = pts[1], quat(0, 0, 0, 1)
      return core_vehicles.spawnNewVehicle(o.model, o)
    end)
    log(ok and "I" or "E", logTag, ok and "spawned Michael's physical body (gta_body)" or ("cannot spawn gta_body: " .. tostring(res)))
    return
  end
  bodySpawnT = bodySpawnT or socket.gettime()
  if socket.gettime() - bodySpawnT < 1.0 then return end
  if not bodyLoaded then
    if not pts then return end
    v.playerUsable = false
    pcall(extensions.gameplay_walk.addVehicleToBlacklist, v:getID())
    v:queueLuaCommand("extensions.load('gtaBody')")
    v:setPositionRotation(pts[1].x, pts[1].y, pts[1].z, 0, 0, 0, 1)
    bodyLoaded = true
    return
  end
  if not pts then parkBody() return end
  bodyParked = false
  if (v:getPosition() - pts[1]):length() > 40 then
    v:setPositionRotation(pts[1].x, pts[1].y, pts[1].z, 0, 0, 0, 1)
    return
  end
  local vx, vy = rotZ(ped.vx or 0, ped.vy or 0, yawRad)
  local t = { string.format("%.2f,%.2f,%.2f", vx, vy, ped.vz or 0) }
  for i, k in ipairs(BODY_PTS) do t[i + 1] = string.format("%.3f,%.3f,%.3f", pts[k].x, pts[k].y, pts[k].z) end
  v:queueLuaCommand("gtaBody.set('" .. table.concat(t, ",") .. "')")
end

local function tick()
  pump()
  local pv = be:getPlayerVehicleID(0)
  if ((puppetId and pv == puppetId) or (bodyId and pv == bodyId)) and extensions.gameplay_walk then
    pcall(extensions.gameplay_walk.setWalkingMode, true, nil, nil, true)
  end
  stat.frames = stat.frames + 1
  local nowS = socket.gettime()
  if nowS - stat.t >= 3 then
    if engaged then
      log("I", logTag, string.format("stat beamFrames/s=%.0f gtaPackets/s=%.0f puppetUpdates/s=%.0f",
        stat.frames / (nowS - stat.t), stat.pkts / (nowS - stat.t), stat.puppetRate))
    end
    stat.frames, stat.pkts, stat.t = 0, 0, nowS
  end
  if engaged and not S.restDumped and ped.fresh and ped.sk and #ped.sk >= 54 and (ped.flags or 0) % 16 == 0
     and math.abs(ped.vx) + math.abs(ped.vy) < 0.05 then
    S.restDumped = true
    local h = math.rad(ped.heading or 0)
    local fx, fy, rx_, ry_ = -math.sin(h), math.cos(h), math.cos(h), math.sin(h)
    local t = {}
    for i = 1, 18 do
      local dx, dy, dz = ped.sk[i * 3 - 2] - ped.gx, ped.sk[i * 3 - 1] - ped.gy, ped.sk[i * 3] - ped.gz
      t[#t + 1] = string.format("{%.3f,%.3f,%.3f}", dx * rx_ + dy * ry_, dx * fx + dy * fy, dz)
    end
    log("I", logTag, "restdump " .. table.concat(t, ","))
  end
  if cfg.autoEngage and not engaged and not manualOff and ped.fresh and getCurrentLevelIdentifier and getCurrentLevelIdentifier() then
    autoAt = autoAt or (nowS + 3)
    if nowS >= autoAt then autoAt = nil guard(engage) end
  else
    autoAt = nil
  end
  local onFoot = true
  local afoot = engaged and getWalker() ~= nil
  holdTab(afoot)
  guard(updateWheel, afoot and not entering and ped.fresh and math.floor((ped.flags or 0) / 524288) % 2 == 1)
  if (ped.shotsDue or 0) > 0 then
    local n = ped.shotsDue
    ped.shotsDue = 0
    if afoot and cfg.bullets then
      local pts = skeletonPoints()
      local mz, md = muzzlePoint(), muzzleDir()
      guard(shoot, n, pts and pts[8], md and mz, md)
    end
  end
  if engaged then
    local nowR = socket.gettime()
    if nowR - S.paceT > 2 then
      S.paceT = nowR
      send(string.format("M|pace|%.2f|%.2f", cfg.runPace, cfg.sprintPace))
      send(string.format("M|slow|%.2f", slow))
    end
    patchWalk()
    onFoot = getWalker() ~= nil
    if onFoot then updateEntering() else entering = nil end
    if not onFoot then
      if not riding then
        riding = true
        log("I", logTag, "player is in a vehicle: Michael parked")
        parkBody()
        pcall(udp.sendto, udp, "Q|hide", cfg.host, 47202)
        if commands.isFreeCamera() then pcall(commands.setGameCamera) end
        local u = walkerId and getObjectByID(walkerId)
        if u and u:getJBeamFilename() == "unicycle" and u:getActive() then pcall(function() u:delete() end) end
        walkerId = nil
        walkerHave = false
      end
      if nowR - S.rideMsgT > 0.5 then S.rideMsgT = nowR; send("M|ride|1") end
      if lastGround then
        local gx, gy, gz = beamToGta(walkerFeet.x, walkerFeet.y, walkerFeet.z)
        seq = seq + 1
        send(string.format("W|%d|%.3f|%.3f|%.3f", seq, gx, gy, gz))
      end
    elseif riding then
      riding = false
      send("M|ride|0")
      needOffset = true
      S.offsetAt = nowR + 0.5
      lastGround = nil
      cam.pivot = nil
      hist = {}
      log("I", logTag, "player is on foot again: re-anchoring Michael")
    end
  end
  if engaged and onFoot then
    if needOffset and socket.gettime() < S.offsetAt then
    elseif needOffset and computeOffset() then
      needOffset = false
      send(string.format("T|%d|%.2f|%.2f|%.2f", seq, cfg.anchorX, cfg.anchorY, cfg.anchorZ))
      tpCheck, tpSent, tpTries = true, socket.gettime(), 0
      arriveT = socket.gettime()
    end
    if arriveT and ped.fresh and ped.gx then
      local there = math.abs(ped.gx - cfg.anchorX) + math.abs(ped.gy - cfg.anchorY) < 3 and math.floor((ped.flags or 0) / 2048) % 2 == 0
      if there or socket.gettime() - arriveT > 3 then
        arriveT = nil
        S.bodyHoldT = socket.gettime() + 1.0
      end
    end
    if tpCheck and not needOffset and ped.fresh and ped.gx then
      if math.abs(ped.gx - cfg.anchorX) + math.abs(ped.gy - cfg.anchorY) < 200 then
        tpCheck = false
      elseif socket.gettime() - tpSent > 0.5 and tpTries < 20 then
        tpTries = tpTries + 1
        tpSent = socket.gettime()
        send(string.format("T|%d|%.2f|%.2f|%.2f", seq, cfg.anchorX, cfg.anchorY, cfg.anchorZ))
      end
    end
    if not needOffset then guard(sendWalker) end
    guard(sendCamera)
    if engaged then
      local pts = skeletonPoints()
      if pts then
        guard(drawSkeleton, pts)
        if not cfg.compose then guard(cfg.usePuppet and drawPuppet or drawBody, pts) end
        if cfg.thirdPerson then
          if not commands.isFreeCamera() then commands.setFreeCamera() end
          pcall(core_camera.setSpeed, 2)
        end
      end
      guard(sendPose)
      guard(updateBody)
      guard(wallsNearby)
      guard(OB.tick)
    end
  end
  local now = socket.gettime()
  if now - S.lastVehSend >= 1 / cfg.vehicleHz then
    S.lastVehSend = now
    guard(sendWorld)
  end
end

local perf = { u = 0, p = 0, c = 0, n = 0, t = socket.gettime() }
local function perfFlush()
  local now = socket.gettime()
  if now - perf.t < 3 then return end
  if perf.n > 0 then
    log("I", logTag, string.format("perf fps=%.1f tick=%.2fms luaKB=%.0f holes=%d tracers=%d pending=%d", perf.n / (now - perf.t), perf.u / perf.n * 1000, collectgarbage("count"), #holes, #tracers, tableSize and tableSize(pending) or 0))
  end
  perf.u, perf.p, perf.c, perf.n, perf.t = 0, 0, 0, 0, now
end

local burning, boomed, lastFireSend = {}, {}, 0
local function onTop(veh)
  local id = veh:getID()
  if not be:getObjectOOBBIsInitialized(id) then return false end
  local d = walkerFeet - vec3(be:getObjectOOBBCenterXYZ(id))
  for i = 0, 2 do
    local ax = vec3(be:getObjectOOBBHalfAxisXYZ(id, i))
    local len = ax:length()
    if len > 1e-3 and math.abs(d:dot(ax) / len) > len + 1.0 then return false end
  end
  return true
end
local function carHazards()
  if not engaged or not walkerHave then return end
  local now = socket.gettime()
  for id, b in pairs(burning) do
    local veh = be:getObjectByID(id)
    if not veh or now - b.t > 3 then
      burning[id] = nil
    elseif now - lastFireSend > 1 then
      lastFireSend = now
      local fd = (vec3(b.x, b.y, b.z) - walkerFeet):length()
      local okTop, top = pcall(onTop, veh)
      if not okTop then log("E", logTag, "on-top check failed: " .. tostring(top)) top = false end
      log("I", logTag, string.format("car fire: distance to the flames %.1f m, on top %s", fd, tostring(top)))
      if top or fd < 2.5 then send("X|ignite") end
    end
  end
  for id in pairs(boomed) do
    boomed[id] = nil
    local veh = be:getObjectByID(id)
    if veh then
      local p = vec3(veh:getPosition())
      if (p - walkerFeet):length() < 25 then
        local gx, gy, gz = beamToGta(p.x, p.y, p.z)
        send(string.format("X|boom|%.3f|%.3f|%.3f", gx, gy, gz))
      end
    end
  end
end

local charred, charOrig = {}, {}
local charFailed
local function rgbOf(c)
  if type(c) ~= "table" and type(c) ~= "userdata" then return end
  local r, g, b = c[1] or c.r or c.x, c[2] or c.g or c.y, c[3] or c.b or c.z
  if not (tonumber(r) and tonumber(g) and tonumber(b)) then return end
  if r > 1 or g > 1 or b > 1 then r, g, b = r / 255, g / 255, b / 255 end
  return { r, g, b }
end
local function charFade()
  local now = socket.gettime()
  for id, c in pairs(charred) do
    local veh = be:getObjectByID(id)
    if not veh or c.done then
      charred[id] = nil
    elseif now - c.last > 0.1 then
      c.last = now
      local f = math.min(1, (now - c.t0) / 12)
      local k = 1 - 0.96 * f
      local base = { c.c0[1] * k, c.c0[2] * k, c.c0[3] * k, c.a }
      local md = c.md
      local paint = { baseColor = base, metallicPaintData = { md[1] * (1 - f), md[2] + (1 - md[2]) * f, md[3] * (1 - f), md[4] + (1 - md[4]) * f } }
      local ok, err = pcall(core_vehicle_manager.liveUpdateVehicleColors, id, veh, 1, paint)
      if not ok and not charFailed then charFailed = true log("E", logTag, "burnt paint failed: " .. tostring(err)) end
      if f >= 1 then c.done = true end
    end
  end
end

local function carFire(id, x, y, z)
  burning[id] = { t = socket.gettime(), x = x, y = y, z = z }
end
local shot = { orig = {}, last = {} }
local function carReset(id)
  shot.restore(id)
  charred[id] = nil
  local o = charOrig[id]
  charOrig[id] = nil
  local veh = be:getObjectByID(id)
  if not (o and veh) then return end
  local paint = o.paint or { baseColor = { o.c0[1], o.c0[2], o.c0[3], o.a }, metallicPaintData = o.md }
  local ok, err = pcall(core_vehicle_manager.liveUpdateVehicleColors, id, veh, 1, paint)
  if not ok then log("E", logTag, "paint restore failed: " .. tostring(err)) end
end

local function carShot(id)
  local now = socket.gettime()
  if shot.last[id] and now - shot.last[id] < 0.4 then return end
  local okT, data = pcall(function() return gameplay_traffic.getTrafficData()[id] end)
  if not (okT and data and data.role) or id == be:getPlayerVehicleID(0) or id == walkerId then return end
  shot.last[id] = now
  local target = walkerId or be:getPlayerVehicleID(0)
  local r = data.role
  if not shot.orig[id] then
    shot.orig[id] = { pullOver = r.actions.pullOver, disabled = r.actions.disabled, askInsurance = r.actions.askInsurance }
    local function keepFleeing() r.state = "flee" end
    r.actions.pullOver, r.actions.disabled, r.actions.askInsurance = keepFleeing, keepFleeing, keepFleeing
  end
  r.lockAction = false
  r.flags.askInsurance = nil
  r:setTarget(target)
  r:setAction("fleePostCrash", { targetId = target, aggression = 1 })
  r.lockAction = true
  data:setAiMode("flee")
  local pid = be:getPlayerVehicleID(0)
  local pd = pid and gameplay_traffic.getTrafficData()[pid]
  if pd and pd.pursuit and pd.pursuit.mode == 0 then gameplay_police.setPursuitMode(1, pid) end
  be:queueObjectLua(id, string.format("ai.setTargetObjectID(%d) electrics.set_warn_signal(0)", target))
end
shot.restore = function(id)
  local o = shot.orig[id]
  shot.orig[id], shot.last[id] = nil, nil
  local okT, data = pcall(function() return gameplay_traffic.getTrafficData()[id] end)
  if o and okT and data and data.role then
    for k, f in pairs(o) do data.role.actions[k] = f end
    data.role.lockAction = false
  end
end

local function carBoom(id)
  boomed[id] = true
  if charOrig[id] then return end
  local paint
  local okp, paints = pcall(function() return core_vehicle_manager.getVehicleData(id).config.paints end)
  if okp and paints and paints[1] then paint = deepcopy(paints[1]) end
  local c0, a, md = paint and rgbOf(paint.baseColor), 1, { 0.3, 0.4, 0.5, 0.1 }
  local src = "config"
  if paint and paint.baseColor then a = paint.baseColor[4] or 1 end
  if paint and paint.metallicPaintData then
    local m = paint.metallicPaintData
    md = { m[1] or 0.3, m[2] or 0.4, m[3] or 0.5, m[4] or 0.1 }
  end
  if not c0 then
    local veh = be:getObjectByID(id)
    local ok, col = pcall(function() return veh:getColor() end)
    c0 = ok and rgbOf(col)
    src = "getColor"
  end
  if not c0 then c0, src = { 0.5, 0.5, 0.5 }, "none" end
  log("I", logTag, string.format("paint source %s (%.2f %.2f %.2f)", src, c0[1], c0[2], c0[3]))
  charOrig[id] = { paint = paint, c0 = c0, a = a, md = md }
  charred[id] = { t0 = socket.gettime(), last = 0, c0 = c0, a = a, md = md }
end

local function onUpdate(dtReal, dtSim)
  if not running then return end
  local t0 = os.clock()
  guard(tick)
  guard(carHazards)
  guard(charFade)
  perf.u = perf.u + os.clock() - t0
  perf.n = perf.n + 1
  perfFlush()
end

local function onPreRender()
  local t0 = os.clock()
  if engaged and running and not riding and not commands.isFreeCamera() then guard(sendPose) end
  if engaged or #holes > 0 or #tracers > 0 then guard(drawHoles) end
  perf.p = perf.p + os.clock() - t0
end

local function onCameraPreRender(cd)
  if not (engaged and running and not riding and cd and cd.res) then return end
  local t0 = os.clock()
  guard(function()
    local pts = skeletonPoints()
    if pts then chaseCam(pts, cd) end
    sendPose(cd)
  end)
  perf.c = perf.c + os.clock() - t0
end

local function onExtensionLoaded()
  pcall(sweepHoleObjects)
  loadConfig()
  start()
end

local function onExtensionUnloaded()
  holdTab(false)
  unpatchWalk()
  stop()
end

local function puppetStat(n)
  local now = socket.gettime()
  if stat.puppetT > 0 and now > stat.puppetT then stat.puppetRate = (n - stat.puppetN) / (now - stat.puppetT) end
  stat.puppetN, stat.puppetT = n, now
end

local function onClientEndMission()
  OB.built, OB.building = false, false
  sunObj = nil
  engaged = false
  manualOff = false
  destroyBody()
  for i = #holes, 1, -1 do dropHole(holes[i]) holes[i] = nil end
  pcall(sweepHoleObjects)
end

M.onUpdate = onUpdate
M.onPreRender = onPreRender
M.onCameraPreRender = onCameraPreRender
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onClientEndMission = onClientEndMission

M.start = start
M.stop = stop
M.align = align
M.here = here
M.engage = engage
M.disengage = disengage
M.set = set
M.status = status
M.puppetStat = puppetStat
M.bulletReply = bulletReply
M.carFire = carFire
M.carBoom = carBoom
M.carShot = carShot
M.carReset = carReset

return M
