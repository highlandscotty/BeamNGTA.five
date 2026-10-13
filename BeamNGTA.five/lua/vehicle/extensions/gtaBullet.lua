local M = {}

local part
local trigger
local engineHits, steamOn, smokeOn, emitT = 0, false, false, 0
local fireAt, blown, fireBeat, blownT, out
local dents = {}
local DENT = 2.4
local FRAMES = 4

local function engineBlock()
  local ok, dev = pcall(powertrain.getDevice, "mainEngine")
  if ok and dev and dev.engineBlockNodes and #dev.engineBlockNodes > 0 then return dev end
end

local function engineStage()
  local dev = engineBlock()
  if not dev then return end
  local n = dev.engineBlockNodes
  if engineHits >= 8 then steamOn = true end
  if engineHits >= 20 and not smokeOn then
    smokeOn = true
    pcall(function() dev:disable() end)
  end
  if engineHits >= 40 and not fireAt and not blown then
    fireAt = os.clock()
    fireBeat = 0
    if fire and fire.flammableNodes and fire.flammableNodes[n[1]] then fire.igniteNode(n[1]) elseif fire then fire.igniteRandomNode() end
  end
  if engineHits >= 90 and fireAt and os.clock() - fireAt > 10 and not blown and fire then
    blown = true
    blownT, out = 0, false
    steamOn, smokeOn, fireAt = false, false, nil
    obj:queueGameEngineLua(string.format("gtaBridge.carBoom(%d)", obj:getId()))
    fire.explodeVehicle()
    for i = 1, 6 do
      obj:addParticleByNodesRelative(n[2] or n[1], n[1], i * 2, 43, 0, 6)
      obj:addParticleByNodesRelative(n[2] or n[1], n[1], -i * 2, 39, 0, 6)
    end
  end
end

local function engineHit(hp)
  local dev = engineBlock()
  if not dev then return false end
  local c, k = vec3(0, 0, 0), 0
  for _, n in ipairs(dev.engineBlockNodes) do c = c + vec3(obj:getNodePosition(n)) k = k + 1 end
  return (hp - c / k):length() < 0.9
end

local function updateGFX(dt)
  if blown and not out then
    blownT = blownT + dt
    if blownT > 6 then
      out = true
      if fire and fire.extinguishVehicle then pcall(fire.extinguishVehicle) end
    end
  end
  if fireAt then
    fireBeat = (fireBeat or 0) + dt
    if fireBeat > 1 then
      fireBeat = 0
      local p = obj:getPosition()
      local dev = engineBlock()
      if dev then p = p + vec3(obj:getNodePosition(dev.engineBlockNodes[1])) end
      obj:queueGameEngineLua(string.format("gtaBridge.carFire(%d, %f, %f, %f)", obj:getId(), p.x, p.y, p.z))
    end
  end
  for i = #dents, 1, -1 do
    local e = dents[i]
    obj:applyForceVector(e.a, e.f * e.u)
    obj:applyForceVector(e.b, e.f * e.v)
    obj:applyForceVector(e.c, e.f * (1 - e.u - e.v))
    e.left = e.left - 1
    if e.left <= 0 then table.remove(dents, i) end
  end
  if not (steamOn or smokeOn) then return end
  emitT = emitT + dt
  if emitT < 0.08 then return end
  emitT = 0
  local dev = engineBlock()
  if not dev then return end
  local n = dev.engineBlockNodes
  local n2 = n[2] or n[1]
  obj:addParticleByNodesRelative(n2, n[1], 1 + math.random() * 2, smokeOn and 42 or 34, 0, 1)
  if smokeOn then obj:addParticleByNodesRelative(n2, n[1], -1 - math.random() * 2, 40, 0, 1) end
end

local function onReset()
  obj:queueGameEngineLua(string.format("if gtaBridge and gtaBridge.carReset then gtaBridge.carReset(%d) end", obj:getId()))
  engineHits, steamOn, smokeOn, emitT, dents, fireAt, blown, blownT, out = 0, false, false, 0, {}, nil, false, nil, false
end

local function glassy(name)
  local n = string.lower(name):gsub("backlight", "rearwindow")
  if n:find("light") or n:find("lamp") or n:find("signal") or n:find("mirror") or n:find("flasher") or n:find("beacon") then return false end
  return (n:find("glass") or n:find("windshield") or n:find("window") or n:find("sunroof")) ~= nil
end

local function sortParts()
  part, trigger = {}, {}
  local data = v.data
  local wheelOf = {}
  for id, w in pairs(data.wheels or {}) do
    if w.pressureGroup then
      wheelOf[w.pressureGroup] = id
      local n = data.pressureGroups and data.pressureGroups[w.pressureGroup]
      if n then wheelOf[n] = id end
    end
  end
  local carrier = {}
  for _, fb in pairs(data.flexbodies or {}) do
    local g = fb.deformGroup
    if type(g) == "string" and glassy(g .. " " .. tostring(fb.mesh)) then
      carrier[g] = carrier[g] or {}
      carrier[g][fb.partPath or ""] = true
    end
  end
  local ends, own = {}, {}
  for _, b in pairs(data.beams or {}) do
    if b.deformSwitches and b.deformGroup then
      for _, g in ipairs(type(b.deformGroup) == "table" and b.deformGroup or { b.deformGroup }) do
        if carrier[g] then
          trigger[g] = trigger[g] or b
          ends[g], own[g] = ends[g] or {}, own[g] or {}
          for _, n in ipairs({ b.id1, b.id2 }) do
            ends[g][n] = true
            local node = data.nodes[n]
            if node and carrier[g][node.partPath or ""] then own[g][n] = true end
          end
        end
      end
    end
  end
  local corners = {}
  for g in pairs(trigger) do
    local n = 0
    for _ in pairs(own[g]) do n = n + 1 end
    corners[g] = n >= 3 and own[g] or ends[g]
  end
  local tris = data.triangles or {}
  for i = 0, tableSizeC(tris) - 1 do
    local t = tris[i]
    local w = t.pressureGroup and wheelOf[t.pressureGroup]
    if w then
      part[i] = "w:" .. w
    else
      for g, c in pairs(corners) do
        if c[t.id1] and c[t.id2] and c[t.id3] then part[i] = "g:" .. g break end
      end
    end
  end
end

local function broken(p)
  local name = p:sub(3)
  if p:sub(1, 1) == "g" then return beamstate.deformGroupsTriggerBeam[name] ~= nil end
  local w = wheels.wheels[tonumber(name)]
  return w ~= nil and w.isTireDeflated == true
end

local function hit(ox, oy, oz, dx, dy, dz, reach, push, shot)
  if not part then sortParts() end
  obj:queueGameEngineLua(string.format("gtaBridge.carShot(%d)", obj:getId()))
  local o, d = vec3(ox, oy, oz) - obj:getPosition(), vec3(dx, dy, dz)
  local at, gone = {}, {}
  local function corner(n)
    local p = at[n]
    if not p then p = vec3(obj:getNodePosition(n)) at[n] = p end
    return p
  end
  local tris = v.data.triangles or {}
  local count = tableSizeC(tris)
  for _ = 1, 4 do
    local best, bu, bv, bt = nil, 0, 0, reach
    for i = 0, count - 1 do
      local p = part[i]
      if p and gone[p] == nil then gone[p] = broken(p) end
      if not (p and gone[p]) then
        local t = tris[i]
        local dist, tu, tv = intersectsRay_Triangle(o, d, corner(t.id1), corner(t.id2), corner(t.id3))
        if dist < bt then best, bu, bv, bt = i, tu, tv, dist end
      end
    end
    if not best then break end
    local t, p = tris[best], part[best]
    local f = d * push * DENT
    local w1, w2, w3 = bu * bu, bv * bv, (1 - bu - bv) ^ 2
    local ws = w1 + w2 + w3
    obj:applyForceVector(t.id1, f * w1 / ws)
    obj:applyForceVector(t.id2, f * w2 / ws)
    obj:applyForceVector(t.id3, f * w3 / ws)
    dents[#dents + 1] = { a = t.id1, b = t.id2, c = t.id3, u = bu, v = bv, f = f, left = FRAMES }
    if not blown and engineHit(o + d * bt) then
      engineHits = engineHits + 1
      engineStage()
    end
    if not p then
      obj:queueGameEngineLua(string.format("gtaBridge.bulletReply(%d, %d, %d, %d, %d, %f, %f)", shot, obj:getId(), t.id1, t.id2, t.id3, bu, bv))
      return
    elseif p:sub(1, 1) == "w" then
      beamstate.deflateTire(tonumber(p:sub(3)))
      obj:queueGameEngineLua(string.format("gtaBridge.bulletReply(%d, %d)", shot, obj:getId()))
      return
    end
    local g = p:sub(3)
    material.switchBrokenMaterial(trigger[g])
    beamstate.deformGroupsTriggerBeam[g] = beamstate.deformGroupsTriggerBeam[g] or trigger[g].cid
    obj:addParticleByNodesRelative(t.id2, t.id1, 1, 68, 0.2, 15)
    obj:addParticleByNodesRelative(t.id2, t.id1, 1, 69, 0.2, 15)
    gone[p] = true
  end
  obj:queueGameEngineLua(string.format("gtaBridge.bulletReply(%d)", shot))
end

M.hit = hit
M.updateGFX = updateGFX
M.onReset = onReset
return M
