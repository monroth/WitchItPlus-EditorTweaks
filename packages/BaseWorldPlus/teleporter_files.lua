-- Independent observer of the producer's actual files. No save/load admission.
local dir=assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))
local Native=dofile(dir..'teleporter_native.lua')
local Store=dofile(dir..'teleporter_store.lua')
local M={}
function M.install(X,T,options)
 local read=options.reader or Store.read
 local F=assert(X.api.shared('Core').layout_files,'native layout files unavailable')
 local E=X.teleporterScope or assert(X.api.Native.scope(X.api.id));X.teleporterScope=E
 local saves,loads,pending,last={},{},nil,nil
 local alive=true
 local function log(message)X.log('Teleporters',message)end
 local function target(e,v)return {world=e.world or v.world,name=e.name,target_path=e.target_path}end
 local function key(o)return tostring(o:GetAddress())..'|'..o:GetFullName()end
 local function document()
  return (options.document or Native.document)(X)
 end
 local function request(e,unpublished)
  pending={event=e,ticks=0,unpublished=unpublished};if not e.recovery then last=e end
  log('loading '..e.target_path..'.fapteleports')
 end
 local function incoming(p,v)
  assert(not p.error,p.error)
  if not p.rows then p.rows,p.source=read(target(p.event,v),function()return true end,'manual')end
  return p.rows
 end
 local function snapshot()
  if not pending then return T.file_snapshot()end
  local v=document();local rows=incoming(pending,v)
  return {rows=Store.copy(rows),revision=pending.source and pending.source.revision or 0,document=v}
 end
 local stop=F.observe(function(e,existing)
  if not alive then return end
  if existing then request(e);return end
  if e.kind=='save' then
   if e.phase=='entry' then
    local ok,snapshot=pcall(snapshot)
    if ok then saves[e.serial]=snapshot
    else log('save snapshot failed; companion preserved: '..tostring(snapshot))end
   elseif e.phase=='complete' then
    local snapshot=saves[e.serial];saves[e.serial]=nil
    if e.success and not e.autosave then
     last=e;T.file_target(target(e,{}),e.owner_key)
     if pending then pending.unpublished=true end
    end
    if e.success and snapshot and snapshot.document.actor_key==e.owner_key then
     T.file_saved(snapshot,target(e,snapshot.document),e.serial,e.autosave)
     if pending and not e.autosave then pending.unpublished=false end
     if not e.autosave then last=e end;log('saved '..e.target_path..'.fapteleports revision='..snapshot.revision)
    end
   end
  elseif e.kind=='load' then
   if e.phase=='entry' then
    pending=nil
    local captured,snapshot=pcall(T.file_snapshot)
    if captured then loads[e.serial]=snapshot end
    local ok,why=T.cleanup();assert(ok,why)
   elseif e.complete then
    local previous=loads[e.serial];loads[e.serial]=nil
    if e.success then request(e)elseif previous then T.file_restore(previous)end
   end
  end
 end,true)
 -- One finite continuation for one incoming file. Poll only class residency;
 -- spawn/application executes once after the engine async request completes.
 local function advance(p)
  p.ticks=p.ticks+1
  assert(p.ticks<=1800,'class load timed out; use bteleport reload')
  local ok,v=pcall(document);if not ok or v.actor_key~=p.event.owner_key then return end
  incoming(p,v) -- retained validated rows; never reread after async residency
  if next(p.rows)then
   if not p.requested then
    -- No repeated request on a later tick or user command.
    for _,gm in pairs(X.Registry.buckets.B_CreativeGameMode_C or {})do
     if gm:IsValid()and key(gm)==v.actor_key then
      p.requested=true;E.load_class(Native.CLASS,gm);break
     end
    end
   end
   local class=StaticFindObject(Native.CLASS)
   if not class or not class:IsValid()then return end
   for _,flag in ipairs({'RF_NeedInitialization','RF_NeedLoad','RF_NeedPostLoad','RF_NeedPostLoadSubobjects'})do
    if EObjectFlags[flag]and class:HasAnyFlags(EObjectFlags[flag])then return end
   end
  end
  T.file_apply(v,p.rows,p.event.recovery,p.unpublished)
  pending=nil
  log('loaded '..p.event.target_path..'.fapteleports')
 end
 local tick=E.on_tick(function()
  local p=pending;if not p or p.error or not alive then return end
  -- Companion errors belong to this observer. Native subscriptions fail-stop on
  -- escaped exceptions, so retain unapplied rows/error here until explicit reload.
  local ok,why=pcall(advance,p)
  if not ok then
   p.error='teleporter companion '..p.event.target_path..'.fapteleports: '..tostring(why)..'; unapplied, use bteleport reload'
   log(p.error)
  end
 end)
 E.on_call('/Game/Blueprints/Gamemodes/CreativeMode/B_CreativeGameMode.B_CreativeGameMode_C:NewLayout','post',function()
  pending=nil;saves={};loads={};last=nil
  local ok,why=T.cleanup();assert(ok,why)
 end)
 X.Lifetime.onReset(function()pending=nil;saves={};loads={};T.abandon()end)
 local B={}
 function B.waiting()return pending~=nil end
 function B.error()return pending and pending.error end
 function B.reload()
  local v=document();local p=pending;local e=p and p.event or F.current(v.actor_key)or last
  assert(e and e.owner_key==v.actor_key and (p or not v.name or e.name==v.name),'no completed native file for this layout')
  request(e,p and p.unpublished);return true
 end
 function B.close()alive=false;pending=nil;saves={};loads={};stop();if tick then tick();tick=nil end;return true end
 return B
end
return M
