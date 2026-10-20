-- Reversible per-layout base scenery suppression; chat + legacy console interfaces.
local M={}
local HEADER='FAPP_HIDDEN_V1'
local LIMIT=256
local STATUE={
 SM_WomanStatue02B_26=true,
 SM_Crystal16=true,SM_Crystal17=true,SM_Crystal18=true,SM_Crystal19=true,
 SM_Crystal20=true,SM_Crystal21=true,SM_Crystal22=true,
 NS_DesertBLueCrystal=true,
 SM_RuneRayCircle3=true,SM_RuneRayCircle4=true,SM_RuneRayCircle5=true,
}
local function copy(t) local r={} for k,v in pairs(t) do r[k]=v end return r end
local function equal(a,b) for k in pairs(a) do if not b[k] then return false end end;for k in pairs(b) do if not a[k] then return false end end;return true end
local function keys(t) local r={} for k in pairs(t) do r[#r+1]=k end table.sort(r) return r end
local function safe(s) return type(s)=='string' and #s>0 and #s<=1024 and not s:find('[%c]') end
function M.encode(level,set)
 assert(safe(level),'invalid level')
 local rows={HEADER,level}
 local list=keys(set); assert(#list<=LIMIT,'too many hidden actors')
 for _,key in ipairs(list) do assert(safe(key),'invalid actor identity'); rows[#rows+1]=key end
 return table.concat(rows,'\n')..'\n'
end
function M.decode(text,level)
 assert(type(text)=='string' and #text<=300000,'invalid suppression file')
 local rows={}
 for line in (text..'\n'):gmatch('(.-)\n') do
  line=line:gsub('\r$','')
  if line~='' then rows[#rows+1]=line end
 end
 assert(rows[1]==HEADER and rows[2]==level,'suppression file version/map mismatch')
 local set={}
 for i=3,#rows do
  assert(safe(rows[i]) and not set[rows[i]],'invalid/duplicate actor identity')
  set[rows[i]]=true
 end
 assert(#rows-2<=LIMIT,'too many hidden actors')
 return set
end
function M.init(X)
 local H,C=X.H,X.C
 local Scenery=dofile(assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))..'scenery.lua')
 local Steps=dofile(assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))..'scenery_steps.lua')
 local classes=Scenery.classes
 local api,queue={},{}
 local commandPending=false
 local pendingAim
 local aimSession=0
 local function cancelAim() pendingAim=nil;aimSession=aimSession+1 end
 local state
 local clientState
 local pendingRestores={}
 local geometryDir=assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))
 local D=assert((X.api or FAPP_API).map_document,'common document service required')
 local Scope=dofile(geometryDir..'maps_geometry_scope.lua')
 local Store=dofile(geometryDir..'maps_geometry_io.lua')
 local GeometrySteps=dofile(geometryDir..'scenery_steps.lua')
 local Native=dofile(geometryDir..'maps_geometry_native.lua')
 local function tokenCurrent(token) return token and not X.Lifetime.transition and D.current(token) end
 local function decorateContext(ctx,token,v)
  ctx.documentToken=token;ctx.documentGeneration=v.document_generation;ctx.ownerGeneration=v.owner_generation
  ctx.worldGeneration=v.world_generation;ctx.worldKey=v.world_key;ctx.epoch=X.Lifetime.epoch;ctx.coreEpoch=v.core_epoch
  ctx.documentName=v.name;ctx.documentKind=v.document_kind
  if not client then ctx.path=v.target_path end
  ctx.geometryScope=Scope.new(D,X.Lifetime,X.Registry,ctx)
  return ctx
 end
 local function bindContext(ctx,client)
  if not ctx then return end
  local token,v=D.capture()
  if not token or not D.current(token) or v.world~=ctx.level
   or v.document_kind=='not_creative' or v.role~=(client and 'client' or 'host') then return end
  if client and (v.document_kind~='saved' or client.level~=v.world or client.name~=v.name
   or client.document_generation~=v.source_generation or client.document_revision~=v.source_revision) then return end
  if X.Lifetime.world and ctx.world~=X.Lifetime.world then return end
  local N=Native.new(X,function() return tokenCurrent(token)==true end)
  if not N.valid(ctx.gm) or N.worldKey(ctx.gm)~=ctx.world or N.pipeKey(ctx.gm)~=v.actor_key then return end
  return decorateContext(ctx,token,v)
 end
 local function lease(s,cleanup)
  return s.geometryScope and (cleanup and s.geometryScope.cleanup() or s.geometryScope.edit())
 end
 local function nativeOwner(s,l,actorCheck)
  return Native.new(X,function()
   return s.geometryScope.current(l)==true and (not actorCheck or actorCheck()==true)
  end)
 end
 local function native(s,l,fn,...)
  local N=nativeOwner(s,l)
  if fn==X.call then return N.call(...) end
  if fn==X.read then return N.read(...) end
  error('unscoped geometry Native operation',0)
 end
 local function checked(s,l,a,identity,class,admission)
  assert(s.geometryScope.actor(l,a,identity,class,admission),'geometry actor owner unavailable')
 end
 local function actorGuard(s,l,r)
  return function()
   s.geometryScope.check(l)
   local N=nativeOwner(s,l)
   assert(N.valid(r.actor) and N.key(r.actor)==r.identity and N.worldKey(r.actor)==s.world,'geometry actor retired/replaced')
   assert(not r.components or not r.components.identity or not (X.Lifetime.retired or {})[r.components.identity],'geometry component retired')
  end
 end
 local function validate(s,l,a,identity,guard)
  local valid,full,key
  local step=GeometrySteps.check(nativeOwner(s,l,guard and function() guard();return true end).bridge(),a,s.world,function(ok,f,k) valid,full,key=ok,f,k end,identity,guard or function() s.geometryScope.check(l) end)
  repeat until step()
  assert(valid,'geometry actor retired/replaced')
  return full,key
 end
 local function scoped(s,l,check)
  return nativeOwner(s,l,check).bridge()
 end

 local function log(s) X.log('Suppression',s) end
 local function context()
  if not C.CreativeMaps or X.Lifetime.transition then return end
  local token,v=D.capture()
  if not token or not tokenCurrent(token) or v.role~='host' or v.document_kind=='not_creative'
   or not safe(v.world) then return end
  local path=v.target_path
  if v.document_kind=='saved' and (type(path)~='string' or not path:lower():match('%.pl$')
   or not (path:sub(1,1)=='/' or path:match('^%a:[/\\]'))) then return end
  local N=Native.new(X,function() return tokenCurrent(token)==true end)
  for _,class in ipairs({'B_CreativeGameMode_C','B_ObjectiveGameMode_C','B_GameMode_C'}) do
   -- Registry.list may perform an opaque validity walk. Use admitted scalar
   -- membership, then explicitly guard each Native lookup and invocation.
   for id,gm in pairs(X.Registry.buckets[class] or {}) do
    local md=(X.Registry.metadata[class] or {})[id]
    if md and md.world==X.Lifetime.world and not (X.Lifetime.retired or {})[id]
     and N.valid(gm) and N.authority(gm) and N.pipeKey(gm)==v.actor_key then
     return bindContext({gm=gm,path=path,level=v.world,world=X.Lifetime.world,creative=class=='B_CreativeGameMode_C'})
    end
   end
  end
 end
 local contextCache
 local function preparedContext()
  local token,v=D.capture()
  if not token or not tokenCurrent(token) or v.role~='host' or v.document_kind=='not_creative'
   or not safe(v.world) then return true end
  local key=table.concat({v.owner_generation,v.document_generation,v.publication_revision,
   X.Lifetime.epoch,X.Registry.revision},':')
  if contextCache and contextCache.key==key and tokenCurrent(contextCache.token) then
   return contextCache.ready,contextCache.value
  end
  local path=v.target_path
  if v.document_kind=='saved' and (type(path)~='string' or not path:lower():match('%.pl$')
   or not (path:sub(1,1)=='/' or path:match('^%a:[/\\]'))) then return true end
  local result={key=key,token=token,ready=false};contextCache=result
  local candidates={}
  for _,class in ipairs({'B_CreativeGameMode_C','B_ObjectiveGameMode_C','B_GameMode_C'}) do
   for id,gm in pairs(X.Registry.buckets[class] or {}) do
    local md=(X.Registry.metadata[class] or {})[id]
    if md and md.world==X.Lifetime.world then candidates[#candidates+1]={class=class,id=id,gm=gm} end
   end
  end
  local tasks={}
  for _,row in ipairs(candidates) do
   local gm=row.gm;local valid,address,full,authority
   local function current()
    return tokenCurrent(token)==true and contextCache==result and not result.ready
     and X.Registry.buckets[row.class][row.id]==gm and not (X.Lifetime.retired or {})[row.id]
   end
   local N=Native.new(X,current)
   local function add(fn) tasks[#tasks+1]=function()
    if not current() or result.value then return true end
    local ok,err=pcall(fn)
    if not current() then return true end
    if not ok then error(err,0) end
    return true
   end end
   tasks[#tasks+1]=X.work.defer(function()
    if not current() or result.value then return function() return true end end
    local step=Steps.check(N.bridge(),gm,X.Lifetime.world,function(ok) valid=ok end,row.id)
    return function()
     if not current() or not N.current() then return true end
     local ok,done=pcall(step)
     if not current() or not N.current() then return true end
     if not ok then error(done,0) end
     return done
    end
   end)
   add(function() if valid then address=N.call(gm,'GetAddress') end end)
   add(function() if valid then full=N.call(gm,'GetFullName') end end)
   add(function() if valid then authority=N.call(gm,'HasAuthority') end end)
   add(function()
    if valid and authority==true and address and full and tostring(address)..'|'..full==v.actor_key then
     result.value=decorateContext({gm=gm,path=path,level=v.world,world=X.Lifetime.world,
      creative=row.class=='B_CreativeGameMode_C'},token,v)
    end
   end)
  end
  tasks[#tasks+1]=function()
   if contextCache==result and tokenCurrent(token) then
    result.ready=true
    if api.invalidate then api.invalidate() end
    if X.wake then X.wake() end
   end
   return true
  end
  if X.work.submit('suppression-document-context:'..key,'native',X.work.sequence(tasks))~=true then
   result.ready=true;result.value=nil
  end
  return result.ready,result.value
 end
 local function restore(s)
  if X.Lifetime.transition or s.epoch~=X.Lifetime.epoch then s.applied={};return true end
  local l=lease(s,true)
  if not l then s.cleanup_pending=next(s.applied)~=nil;return not s.cleanup_pending end
  local failed={}
  for key,r in pairs(s.applied) do
   if (X.Lifetime.retired or {})[r.identity] then -- delivered native retirement owns this actor
   else
    local guard=actorGuard(s,l,r)
    local N=nativeOwner(s,l,function() guard();return true end)
    local ok,err=pcall(function()
     guard();validate(s,l,r.actor,r.identity,guard)
     if r.components and r.components.component then
      assert(N.read(r.actor,r.components.field)==r.components.component,'geometry component replaced')
      validate(s,l,r.components.component,r.components.identity,guard)
      Scenery.restore(N.bridge(),r.actor,r.components,true,guard)
     end
     if r.hidden~=nil then
      guard();N.call(r.actor,'SetActorHiddenInGame',r.hidden)
      guard();assert(N.read(r.actor,'bHidden')==r.hidden,'actor did not restore hidden flag')
     end
     if r.collision~=nil then
      guard();N.call(r.actor,'SetActorEnableCollision',r.collision)
      guard();assert(N.read(r.actor,'bActorEnableCollision')==r.collision,'actor did not restore collision flag')
     end
    end)
    if X.Lifetime.transition or s.epoch~=X.Lifetime.epoch then s.applied={};return true end
    if not ok then failed[key]=r;s.cleanup_error=err end
   end
  end
  s.applied=failed;s.cleanup_pending=next(failed)~=nil
  return not s.cleanup_pending
 end
 -- Failed live rollback stays owned until a retry succeeds. Proven travel
 -- drops snapshots before any read through departing engine objects.
 local function generation() return WIR_RUNTIME and WIR_RUNTIME.world_generation end
 local restoreRevision=0
 local function attemptToken(s,revision)
  return table.concat({tostring(s.world),tostring(X.Lifetime.epoch),tostring(generation()),
   tostring(X.Registry and X.Registry.revision),tostring(revision)},'|')
 end
 local function rememberRestore(s)
  if s and next(s.applied or {}) then
   pendingRestores[#pendingRestores+1]={snapshot=s,
    epoch=X.Lifetime.epoch,generation=generation()}
  end
 end
 local function retryRestores()
  if X.Lifetime.transition or WIR_RUNTIME and WIR_RUNTIME.loading then pendingRestores={};return true end
  local failed={}
  for _,r in ipairs(pendingRestores) do
   if r.epoch==X.Lifetime.epoch and r.generation==generation() then
    local token=attemptToken(r.snapshot,restoreRevision)
    if r.attempt~=token then r.attempt=token;r.complete=restore(r.snapshot) end
    if not r.complete then failed[#failed+1]=r end
   end
  end
  pendingRestores=failed
  local errors={};for _,r in ipairs(failed)do local s=r.snapshot;errors[#errors+1]='hidden scenery '..tostring(s.level)..'/'..tostring(s.documentName)..': '..tostring(s.cleanup_error or 'rollback document unavailable') end
  return #failed==0,table.concat(errors,' | ')
 end
 local inventories={}
 local function inventoryToken(s) return s.world..':'..s.ownerGeneration..':'..s.documentGeneration..':'..X.Registry.revision..':'..tostring(s.creative==true) end
 local function collect(s,a,found)
  local l=assert(lease(s,false),'geometry document retired')
  for class,bucket in pairs(X.Registry.buckets) do
   for id,obj in pairs(bucket) do if obj==a and X.Registry.metadata[class][id].world==s.world then
    local admission=assert(s.geometryScope.admission(l,a,id,class))
    local guard=function() s.geometryScope.check(l);checked(s,l,a,id,class,admission) end
    local full,key=validate(s,l,a,id,guard)
    local SX=scoped(s,l,function() guard();return true end)
    guard();local allowed=Scenery.eligible(SX,a,full);guard()
    if allowed and SX.call(a,'HasAnyFlags',(EObjectFlags and EObjectFlags.RF_WasLoaded) or 0x80000)==true then
     local identity=full:gsub('UEDPIE_%d+_','');local name=identity:match('[:%.]PersistentLevel%.([%w_]+)$')
     if name and identity:find('/Game/Maps/',1,true) and safe(identity) then
      assert(not found[identity],'ambiguous actor identity')
      found[identity]={actor=a,name=name,identity=key,class=class,admission=admission,field=Scenery.componentFields[full:match('^(%S+)')]}
     end
    end
    return
   end end
  end
 end
 -- Listing names uses the registry's current-world actor snapshot. Component
 -- getters and bounds belong to the selected edit or explicit aim/near request.
 local function prepared(s,metadata)
  if not X.work then return true end
  local l=lease(s,false);if not l then return false end
  local token=inventoryToken(s);local cached=inventories[token]
  if not cached then
   X.work.cancel('scenery inventory');inventories={}
   cached={world=s.world,ready=true};inventories[token]=cached
   for _,class in ipairs(classes)do
    for id,a in pairs(X.Registry.buckets[class] or {})do
     local md=(X.Registry.metadata[class] or {})[id]
     local full=md and (md.name or id:match('^[^:]+:(.*)$'))
     local key=full and full:gsub('UEDPIE_%d+_','')
     local name=key and key:match('[:%.]PersistentLevel%.([%w_]+)$')
     if md and md.world==s.world and not (X.Lifetime.retired or {})[id]
      and name and safe(key)and key:find('/Game/Maps/',1,true)and not key:find('Default__',1,true)then
      local old=cached[key]
      assert(not old or old.identity==id,'ambiguous actor identity')
      -- Class queries/notifications can place the same actor in a base and
      -- derived bucket. Keep one row, preferring its concrete class membership.
      if not old or class==full:match('^(%S+)')then
       cached[key]={actor=a,name=name,identity=id,class=class,
        admission=s.geometryScope.admission(l,a,id,class),field=Scenery.componentFields[class]}
      end
     end
    end
   end
  end
  if not metadata then return true end
  if cached.metadataReady then return true end
  if X.work.keys['scenery inventory']then return false end
  local tasks={}
  for key,r in pairs(cached)do if type(r)=='table'then
   local eligible=false
   local AX=scoped(s,l,function()return s.geometryScope.actor(l,r.actor,r.identity,r.class,r.admission)==true end)
   tasks[#tasks+1]=X.work.defer(function()return Steps.check(AX,r.actor,s.world,function(ok)eligible=ok end,r.identity)end)
   tasks[#tasks+1]=function()
    if eligible then eligible=Scenery.eligible(AX,r.actor,key)and AX.call(r.actor,'HasAnyFlags',(EObjectFlags and EObjectFlags.RF_WasLoaded)or 0x80000)==true end
    if not eligible then cached[key]=nil;return true end
    r.component=AX.read(r.actor,r.field or 'StaticMeshComponent')
    if r.class=='StaticMeshActor'then r.meshComponent=r.component;r.component=nil end
    return true
   end
   tasks[#tasks+1]=X.work.defer(function()return eligible and Scenery.metadataSteps(AX,r,Steps)or function()return true end end)
  end end
  tasks[#tasks+1]=function()cached.metadataReady=true;if api.invalidate then api.invalidate()end;if X.wake then X.wake()end;return true end
  local job=X.work.sequence(tasks)
  X.work.submit('scenery inventory','requested scenery bounds',function()
   if not s.geometryScope.current(l)or inventories[token]~=cached then return true end
   return job()
  end)
  log('waiting for requested aim/near component bounds; actor-name lists remain available')
  return false
 end
 local function inventory(s)
  local found={}
  if X.work then
   local cached=inventories[inventoryToken(s)]
   assert(cached and cached.ready,'scenery inventory is settling; retry the command')
   for key,r in pairs(cached) do if type(r)=='table' then found[key]=r end end
  else
   for _,class in ipairs(classes) do for _,a in pairs(X.Registry.buckets[class] or {}) do collect(s,a,found) end end
  end
  -- Saved actors need no birth notification to be inspected or shown again.
  for key,r in pairs(s.resolved or {})do found[key]=r end
  return found
 end
 local function resolveSaved(s,desired)
  local l=assert(lease(s,false),'geometry document retired')
  local N=nativeOwner(s,l);local found,missing={},{}
  s.missingLogged=s.missingLogged or {}
  for _,key in ipairs(keys(desired))do
   local ok,row=pcall(function()
    local class,path=key:match('^(%S+) (.+)$')
    local allowed=false;for _,candidate in ipairs(classes)do if candidate==class then allowed=true;break end end
    local name=path and path:match('[:%.]PersistentLevel%.([%w_]+)$')
    assert(allowed and name and path:find('/Game/Maps/',1,true) and not path:find('Default__',1,true),'invalid saved scenery identity')
    local a=N.object(path)
    assert(N.worldKey(a)==s.world,'saved actor belongs to another world')
    local full=N.call(a,'GetFullName')
    assert(type(full)=='string' and full:gsub('UEDPIE_%d+_','')==key,'saved actor identity differs')
    assert(Scenery.eligible(N.bridge(),a,full) and N.call(a,'HasAnyFlags',(EObjectFlags and EObjectFlags.RF_WasLoaded)or 0x80000)==true,'saved actor is not authored scenery')
    return {actor=a,name=name,identity=assert(N.key(a)),class=class,field=Scenery.componentFields[class]}
   end)
   N.check() -- A document change is a transaction failure, not a missing row.
   if ok then found[key]=row
   else
    missing[key]=tostring(row)
    if s.missingLogged[key]~=missing[key]then
     log('saved hide unapplied; row preserved: '..key..' reason='..missing[key]);s.missingLogged[key]=missing[key]
    end
   end
  end
  s.resolved=s.resolved or {}
  for key in pairs(missing)do s.resolved[key]=nil end
  for key,row in pairs(found)do s.resolved[key]=row end
  s.unapplied=missing
  return found
 end
 local function apply(s,desired,resolved)
  local l=assert(lease(s,false),'geometry document retired')
  local found=resolved or resolveSaved(s,desired)
  if not restore(s) then return false,'could not restore previous state' end
  local ok,err=pcall(function()
   for _,key in ipairs(keys(found)) do
    local row=found[key];local a=row.actor
    local r={actor=a,identity=row.identity,class=row.class,admission=row.admission}
    local guard=actorGuard(s,l,r);local N=nativeOwner(s,l,function() guard();return true end);guard();validate(s,l,a,r.identity,guard)
    assert(Scenery.eligible(N.bridge(),a,key)and N.call(a,'HasAnyFlags',(EObjectFlags and EObjectFlags.RF_WasLoaded)or 0x80000)==true,'actor is not authored scenery: '..key)
    r.hidden=N.read(a,'bHidden');guard()
    r.collision=N.read(a,'bActorEnableCollision');guard()
    assert(type(r.hidden)=='boolean' and type(r.collision)=='boolean','actor flags unavailable')
    s.applied[key]=r -- own partial allocation/mutation before any Native setter
    r.components={}
    if row.field then
     local c=N.read(a,row.field);guard();assert(c,'scenery component unavailable')
     local _,id=validate(s,l,c,nil,guard)
     r.components={component=c,field=row.field,identity=id}
     if row.field=='LightComponent' then r.components.visible=N.read(c,'bVisible')
     elseif row.field=='AudioComponent' then r.components.playing=N.call(c,'IsPlaying')
     else r.components.active=N.call(c,'IsActive') end
     guard();Scenery.hide(N.bridge(),a,r.components,guard)
    end
    guard();N.call(a,'SetActorHiddenInGame',true)
    guard();N.call(a,'SetActorEnableCollision',false)
    guard();assert(N.read(a,'bHidden')==true,'actor did not accept hidden flag')
    guard();assert(N.read(a,'bActorEnableCollision')==false,'actor did not accept collision flag')
   end
  end)
  if not ok then
   if tokenCurrent(l.token) then restore(s) else s.cleanup_pending=next(s.applied)~=nil end
   return false,err
  end
  return true
 end
 -- Runtime mutations are transactions: one component or actor flag per step,
 -- then owned desired/dirty publication. Manual Save owns disk commit.
 local function applyAsync(s,desired,done,resolved)
  assert(not s.busy,'hide transaction already pending')
  local l=assert(lease(s,next(desired)==nil),'geometry document retired')
  local found=resolved or resolveSaved(s,desired)
  s.busy=true
  local failed
  local previous=keys(s.applied)
  local selected=keys(found)
  local function guarded(fn)
   return function()
    if not s.geometryScope.current(l) then failed='geometry document retired';return true end
    if not failed then local ok,err=pcall(fn);if not ok then failed=err end end
    if not s.geometryScope.current(l) then failed='geometry document retired' end
    return true
   end
  end
  local function one(key,restoring)
   local r=restoring and s.applied[key] or {actor=found[key].actor,identity=found[key].identity,class=found[key].class,admission=found[key].admission}
   if restoring and (X.Lifetime.retired or {})[r.identity] then return function() s.applied[key]=nil;return true end end
   local a=r.actor
   r.identity=r.identity or found[key] and found[key].identity
   local valid,componentValid,componentIdentity=true,true
   local snapshot
   local guard=actorGuard(s,l,r)
   local AX=scoped(s,l,function() guard();return true end)
   local tasks={Steps.check(AX,a,s.world,function(ok) valid=ok end,r.identity,guard)}
   local function add(fn) tasks[#tasks+1]=guarded(function()
    if r.identity and (X.Lifetime.retired or {})[r.identity] then
     valid=false;if not restoring then error('scenery retired during transaction') end
    end
    if componentIdentity and (X.Lifetime.retired or {})[componentIdentity] then
     componentValid=false
    end
    guard();fn();guard()
   end) end
   add(function()
    if restoring then return end
    assert(valid,'scenery retired during transaction')
    assert(Scenery.eligible(AX,a,key)and AX.call(a,'HasAnyFlags',(EObjectFlags and EObjectFlags.RF_WasLoaded)or 0x80000)==true,'actor is not authored scenery: '..key)
    s.applied[key]=r -- retain partial snapshot for rollback/travel restore
    r.components={}
   end)
   if not restoring then
    add(function() r.hidden=AX.read(a,'bHidden');assert(type(r.hidden)=='boolean','actor hidden flag unavailable: '..key) end)
    add(function() r.collision=AX.read(a,'bActorEnableCollision');assert(type(r.collision)=='boolean','actor collision flag unavailable: '..key) end)
    add(function()
     local record=found[key]
     if record.field then snapshot={component=AX.read(a,record.field),field=record.field};assert(snapshot.component,'scenery component unavailable: '..record.field) end
    end)
   end
   tasks[#tasks+1]=X.work.defer(function()
    local c=(snapshot or r.components) and (snapshot or r.components).component
    if failed or not valid or not c then return function() return true end end
    guard()
    if restoring then assert(AX.read(a,r.components.field)==c,'geometry component replaced') end
    return Steps.check(AX,c,s.world,function(ok,_,id) componentValid=ok;componentIdentity=id end,r.components and r.components.identity,guard)
   end)
   if not restoring then add(function()
    local c=snapshot and snapshot.component;if not c then return end
    assert(componentValid,'scenery component unavailable: '..snapshot.field)
    if snapshot.field=='LightComponent' then
     snapshot.visible=AX.read(c,'bVisible');assert(type(snapshot.visible)=='boolean','light visibility unavailable')
    elseif snapshot.field=='AudioComponent' then
     snapshot.playing=AX.call(c,'IsPlaying');assert(type(snapshot.playing)=='boolean','audio activity unavailable')
    else
     snapshot.active=AX.call(c,'IsActive');assert(type(snapshot.active)=='boolean','effect activity unavailable')
    end
    snapshot.identity=componentIdentity;r.components=snapshot
   end) end
   add(function()
    if not valid then return end
    assert(componentValid,'scenery component retired')
    if restoring then Scenery.restore(AX,a,r.components,true,guard) else Scenery.hide(AX,a,r.components,guard) end
   end)
   add(function() if valid and r.hidden~=nil then
    local value=true;if restoring then value=r.hidden end;AX.call(a,'SetActorHiddenInGame',value)
   end end)
   add(function() if valid and r.collision~=nil then
    local value=false;if restoring then value=r.collision end;AX.call(a,'SetActorEnableCollision',value)
   end end)
   add(function() if valid and r.hidden~=nil then
    local value=true;if restoring then value=r.hidden end
    assert(AX.read(a,'bHidden')==value,'actor did not accept hidden flag: '..key)
   end end)
   add(function() if valid and r.collision~=nil then
    local value=false;if restoring then value=r.collision end
    assert(AX.read(a,'bActorEnableCollision')==value,'actor did not accept collision flag: '..key)
   end end)
   add(function() if restoring then s.applied[key]=nil end end)
   return X.work.sequence(tasks)
  end
  local function each(list,restoring)
   local cursor,step=0
   return function()
    if not s.geometryScope.current(l) then failed='geometry document retired';return true end
    if step then local ok,done=pcall(step);if not ok then failed=done;step=nil;return true end;if done then step=nil end;return false end
    cursor=cursor+1;if not list[cursor] then return true end
    step=one(list[cursor],restoring);return false
   end
  end
  X.work.submit('hide transaction','scenery component/flag',X.work.sequence({
   each(previous,true),each(selected,false),function()
    if not s.geometryScope.current(l) then failed='geometry document retired';s.cleanup_pending=next(s.applied)~=nil end
    s.cleanup_pending=failed~=nil and next(s.applied)~=nil or nil
    s.busy=false;done(not failed,failed)
    -- A failure is terminal for this attempt. Already queued commands still
    -- own work, but a failed transaction cannot wake its own retry.
    if s.geometryScope.current(l) and (not failed or #queue>0) then
     if api.invalidate then api.invalidate() end
     if X.wake then X.wake() end
    end
    return true
   end,
  }))
 end
 local function restoreSettled(s)
  if not X.work then return restore(s) end
  if next(s.applied)==nil then return true end
  local token=attemptToken(s,restoreRevision)
  if not s.busy and s.restoreAttempt~=token then
   s.restoreAttempt=token
   applyAsync(s,{},function(ok,err)
    if not ok then log('restore failed (owned; awaiting new scenery or explicit reload): '..tostring(err)) end
   end)
  end
  return false
 end
 local function publish(s,set)
  if not tokenCurrent(s.documentToken) then return false,'document_retired' end
  if X.ModSync and s.publishedSet~=set then
   local accepted,why=X.ModSync.publish(s.gm,s.level,set,s.documentToken)
   if accepted==true and tokenCurrent(s.documentToken) then s.publishedSet=set end
   return accepted,why
  end
  return true
 end
 local Files=(X.api or FAPP_API).shared('Core').geometry_files.new(X.api or FAPP_API,X,M,Store,function()return state end)
 -- Resolve exact saved paths now; cooked actors may never emit registry births.
 -- Missing rows remain authored intent, independently of the actors we can apply.
 local function applySaved(s)
  local ok,why=pcall(function()
   local found=resolveSaved(s,s.desired)
   local function done(success,reason)
    s.pendingApply=false;s.error=not success and tostring(reason)or nil
    if success then log('loaded '..#keys(found)..' hidden actors for '..tostring(s.path)..'; unapplied='..#keys(s.unapplied))
    else log('saved hides apply failed: '..s.error)end
   end
   if X.work then applyAsync(s,s.desired,done,found)
   else local success,reason=apply(s,s.desired,found);done(success,reason)end
  end)
  if not ok then s.pendingApply=false;s.error=tostring(why);log('saved hides apply failed: '..s.error)end
 end
 local function load(s)
  s.applied=s.applied or {};s.desired=s.desired or {};s.committed=s.committed or {};s.undo={}
  local ok,rows,dirty=pcall(Files.read,s)
  if not ok then Files.failed(s,rows);error(rows,0)end
  Files.loaded(s);s.error=nil
  s.applied={};s.desired=rows;s.resolved={};s.unapplied={};s.undo={};s.pendingApply=false
  s.committed=dirty and {}or copy(rows);s.geometryRevision=0;s.dirty=dirty
  if not s.path and not next(rows)then return end
  s.pendingApply=true
  applySaved(s)
 end
 local function change(s,set)
  assert(s.creative and X.editing(s.gm),'edit suppression only in Creative edit mode')
  local changeToken=s.documentToken
  assert(tokenCurrent(changeToken),'geometry document retired')
  M.encode(s.level,set) -- validate size/identities before any native mutation
  local previous=copy(s.desired)
  if X.work then
   applyAsync(s,set,function(ok,err)
    if not ok then
     if not tokenCurrent(changeToken) then s.cleanup_pending=next(s.applied)~=nil;s.undoing=nil;return end
     log('geometry change failed: '..tostring(err))
     -- Requeue after this job retires its key; no native operation on a timer.
     s.busy=true;s.undoing=nil
     X.defer(function()
      s.busy=false
      applyAsync(s,previous,function(recovered,rerr)
       if not recovered then s.error=tostring(rerr);log('rollback incomplete: '..s.error) end
      end)
     end)
     return
    end
    if not tokenCurrent(changeToken) then s.cleanup_pending=next(s.applied)~=nil;return end
    if s.undoing then table.remove(s.undo);s.undoing=nil else s.undo[#s.undo+1]=previous end
    s.desired=copy(set)
  s.geometryRevision=(s.geometryRevision or 0)+1
  s.dirty=not equal(s.desired,s.committed or {})
    publish(s,s.desired)
    log(#keys(set)..' hidden actors (unsaved) for '..tostring(s.path or '(unsaved document)'))
   end)
   return
  end
  local ok,err=apply(s,set)
  if not ok then
   if not tokenCurrent(changeToken) then s.cleanup_pending=next(s.applied)~=nil;error(err,0) end
   local recovered,rerr=apply(s,previous)
   if not recovered then log('rollback incomplete: '..tostring(rerr)) end
   error(err)
  end
  assert(tokenCurrent(changeToken),'geometry document retired')
  s.undo[#s.undo+1]=previous
  s.desired=copy(set)
  s.geometryRevision=(s.geometryRevision or 0)+1
  s.dirty=not equal(s.desired,s.committed or {})
  publish(s,s.desired)
  log(#keys(set)..' hidden actors (unsaved) for '..tostring(s.path or '(unsaved document)'))
 end
 local function undo(s)
  local previous=s.undo[#s.undo]; assert(previous,'nothing to undo in this layout session')
  if X.work then s.undoing=true;change(s,previous)
  else change(s,previous);table.remove(s.undo);table.remove(s.undo) end
 end
 local dir=assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))
 local tools=dofile(dir..'maps_hide_tools.lua').init(X,{inventory=inventory,change=change,undo=undo,enqueue=function(...) return api.enqueue(...) end,
  current=function(s) return s and tokenCurrent(s.documentToken) end,
  nativeOwner=function(s,cleanup,actor,id,class,parentCurrent,admission)
   local l=assert(lease(s,cleanup),'geometry document unavailable')
   return nativeOwner(s,l,function()
    return (not parentCurrent or parentCurrent()==true) and (not actor or s.geometryScope.actor(l,actor,id,class,admission)==true)
   end)
  end,
  blinkGuard=function(s,a,id,class,cleanup)
   local l=assert(lease(s,cleanup),'blink document cleanup pending')
   return function() s.geometryScope.check(l);checked(s,l,a,id,class) end
  end,
  editable=function() return state and state.creative and not state.error and C.CreativeMaps and not X.Lifetime.transition end})
 local function run(s,args,chat)
  local action=args[1] or 'help'
  if action=='cleanup' then assert(api.cleanup(),'hide cleanup pending; replacement blocked');log('cleanup: owned scenery restored');return end
  if (chat and action~='group' and action~='hidegroup' and action~='showgroup' and action~='statue' and action~='reload') or action=='near' or action=='aim' or action=='target' or action=='_aimhide' or action=='save' or tonumber(action) or (action=='show' and tonumber(args[2])) then
   return tools.run(s,args)
  end
   assert(tools.reset()~=false,'hide cleanup pending; run /hide cleanup') -- before any backend snapshot
  local _,view=D.capture()
  assert(type(view)=='table','Save the map first, then use bwhide')
  assert(view.role=='host','Host only: ask the host to edit scenery')
  assert(view.document_kind=='saved','Save the map first, then use bwhide')
  assert(s,'Current Creative world scenery is not available; use bwhide reload')
  assert(not s.error or action=='reload','layout suppression needs reload: '..tostring(s.error))
  if action=='group' or action=='hidegroup' or action=='showgroup' then
   local found=inventory(s); local selected={}
   assert(args[2],'use exact eligible actor names from bwhide list')
   for i=2,#args do
    local root
    for key,r in pairs(found) do if r.name==args[i] then assert(not root,'ambiguous name'); root=key end end
    assert(root,'no eligible actor: '..tostring(args[i]))
    for _,key in ipairs(Scenery.group(scoped(s,assert(lease(s,false))),found,root,s.level,function() assert(tokenCurrent(s.documentToken),'geometry document retired') end)) do selected[key]=true end
   end
   local members=keys(selected)
   for _,key in ipairs(members) do log('group: '..found[key].name) end
   if action~='group' then
    local set=copy(s.desired)
    for _,key in ipairs(members) do set[key]=action=='hidegroup' or nil end
    change(s,set)
   end
  elseif action=='diagnose' then
   local l=assert(lease(s,false));local N=nativeOwner(s,l)
   for _,cls in ipairs(classes) do
    local n=0
    for id,a in pairs(X.Registry.buckets[cls] or {}) do
     if s.geometryScope.actor(l,a,id,cls) and N.valid(a) then
      log('raw='..N.call(a,'GetFullName')..'; sameWorld='..tostring(N.sameWorld(a,s.gm)))
      n=n+1;if n>=5 then break end
     end
    end
    log(cls..' admitted count='..n)
   end
  elseif action=='list' then
   log('Scenery: '..#keys(inventory(s)))
   local filter=(args[2] or ''):lower()
   for key,r in pairs(inventory(s)) do
    if r.name:lower():find(filter,1,true) then log((s.desired[key] and '[hidden] ' or '')..r.name) end
   end
  elseif action=='inspect' then
    local matched=false
    for _,r in pairs(inventory(s)) do
        if r.name==args[2] then
            matched=true
            local a=r.actor
            local l=assert(lease(s,false));local guard=actorGuard(s,l,r)
            local N=nativeOwner(s,l,function()guard();return true end)
            local component=N.read(a,'StaticMeshComponent')
            local collision='unknown'
            if N.valid(component) then
                local ok,value=pcall(function() return N.call(component,'GetCollisionEnabled') end)
                if ok then collision=tostring(value) end
            end
            log(r.name..' hidden='..tostring(N.read(a,'bHidden'))..
                ' actorCollision='..tostring(N.read(a,'bActorEnableCollision'))..
                ' primitiveCollision='..collision)
        end
    end
    assert(matched,'no eligible actor matched')
  elseif action=='hide' or action=='show' or action=='statue' then
   local set=copy(s.desired); local count=0
   if action=='statue' then assert(s.level=='DesertTown','statue preset is DesertTown only') end
   for key,r in pairs(inventory(s)) do
    if (action=='statue' and STATUE[r.name]) or (action~='statue' and r.name==args[2]) then
     set[key]=action~='show' or nil; count=count+1
    end
   end
   assert(count>0,'no eligible actor matched')
   if action=='statue' then assert(count==12,'statue group incomplete; no changes applied') end
   change(s,set)
  elseif action=='clear' then change(s,{})
  elseif action=='undo' then
   undo(s); log('Undone. Save the map to keep it.')
  elseif action=='reload' then
   if X.work then
    applyAsync(s,{},function(ok,err)
     if ok then X.defer(function() load(s) end) else s.error=tostring(err) end
    end)
   else assert(restore(s),'restore failed');load(s);s.error=nil end
  else
   log('bwhide list [text] | inspect <exact actor name> | hide <exact actor name> | show <exact actor name> | statue | undo | clear | reload')
  end
 end
 if X.commandHandler then
  for _,root in ipairs({'bwhide','faphide'}) do
   X.commandHandler(root,function(_,parameters)
    api.enqueue(X.values(parameters),false)
    return true
   end)
  end
 end
 function api.enqueue(args,chat,key)
  if args[1]=='status' then
   local token,v=D.capture()
   local message='status: role='..tostring(v and v.role or 'unbound')..' layout='..tostring(v and v.name or '')
    ..' dirty='..tostring(state and not equal(state.desired,state.committed or {})or false)
    ..' error='..tostring(state and (state.error or state.fileError))..' unapplied='..#keys(state and state.unapplied or {})..' queued='..#queue
   log(message);if X.reply then X.reply('Hide',(v and v.name~='' and ('Map: '..v.name..'. ')or 'No saved map. ')..(state and not equal(state.desired,state.committed or {}) and 'Unsaved changes.'or 'Changes saved.')..(state and (state.error or state.fileError)and ' Some edits could not be loaded; use bwhide reload.'or ''))end
   return true
  end
  if args[1]=='reload' then restoreRevision=restoreRevision+1 end
  if #queue<16 then
   queue[#queue+1]={args=args,chat=chat,key=key}
   log('queued '..table.concat(args,' ')..'; next game tick (after any active scenery edit)')
  elseif X.queueReply then X.queueReply('Hide','Command queue full; retry') end
 end
 local function aimWorld()
  -- Late enable has no replayed world_ready event; these saved contexts already
  -- passed the same native world checks as ordinary suppression settlement.
  local ctx=contextCache and contextCache.ready and contextCache.value
  return X.Lifetime.world or state and state.world or ctx and ctx.world
 end
 function api.key(action)
  if action~='aim' then return tools.key(action) end
  -- One idempotent intent: repeats while preparing must not silently cancel aim.
  if pendingAim then log('Home already queued; waiting for geometry readiness');return end
  local world=aimWorld()
  if not C.CreativeMaps or X.Lifetime.transition or not world then return end
  pendingAim={world=world,epoch=X.Lifetime.epoch,session=aimSession}
  log(tools.active() and 'Home queued: turn aim OFF' or 'Preparing geometry; aim will turn ON when ready')
  if api.invalidate then api.invalidate() end
  if X.wake then X.wake() end
 end
 function api.active() return pendingAim~=nil or tools.active() or #queue>0 or commandPending or state and (state.busy or state.pendingApply) or clientState and clientState.busy end
 function api.tick(time)
  if state and state.busy or clientState and clientState.busy then return end
  if #queue>0 or pendingAim then api.poll() end
  tools.tick(state,time)
 end
 function api.poll()
  if pendingAim and (pendingAim.world~=aimWorld() or pendingAim.epoch~=X.Lifetime.epoch or pendingAim.session~=aimSession or X.Lifetime.transition or not C.CreativeMaps) then cancelAim() end
  if X.Lifetime.transition or commandPending or state and state.busy or clientState and clientState.busy then return end
  if not retryRestores() then return end
  if state and state.reloadRequested then
   if not restoreSettled(state) then return end
    if tools.reset()==false then return end
    state=nil
  end
  local ctx
  if X.work then
   local ready;ready,ctx=preparedContext();if not ready then return end
  else ctx=context() end
  if pendingAim and (not ctx or not ctx.creative) then
   cancelAim();log('Home ignored: open a Creative layout as host')
  end
  if ctx then
   local request=queue[1];local action=request and request.args[1]
   local bounds=not request and pendingAim~=nil or action=='aim'or action=='near'or action=='_aimhide'or request and request.chat==true
   if not prepared(ctx,bounds)then return end
  end
  if X.ModSync then
   local snapshot=X.ModSync.clientSnapshot()
   if not ctx and snapshot and C.CreativeMaps and (X.Lifetime.world==snapshot.world) then
    if clientState and (clientState.world~=snapshot.world or clientState.session~=snapshot.session) then
     if not restoreSettled(clientState) then return end
     clientState=nil
    end
    if not clientState then clientState=bindContext({gm=snapshot.gm,world=snapshot.world,level=snapshot.level,session=snapshot.session,applied={}},snapshot);if not clientState then return end end
    if not prepared(clientState) then return end
    local token=attemptToken(snapshot,snapshot.revision)
    if clientState.revision~=snapshot.revision and clientState.attempt~=token then
     clientState.attempt=token -- reserve before native/queue entry, including throws
     if X.work then
      local target=clientState
      applyAsync(target,snapshot.desired,function(ok,err)
       if ok then target.revision=snapshot.revision;target.desired=copy(snapshot.desired)
       else X.once('suppression-client-wait:'..snapshot.world,'Suppression','waiting for local map actors: '..tostring(err)) end
      end)
     else
     local ok,result,err=pcall(apply,clientState,snapshot.desired)
     if ok and result then
      clientState.revision=snapshot.revision
      clientState.desired=copy(snapshot.desired)
      log('client applied revision='..snapshot.revision..'; hidden='..#keys(snapshot.desired))
     else
      if clientState.desired then pcall(apply,clientState,clientState.desired) end
      X.once('suppression-client-wait:'..snapshot.world,'Suppression','waiting for local map actors: '..tostring(ok and err or result))
     end
     end
    end
   elseif clientState then
    if not restoreSettled(clientState) then return end
    clientState=nil
   end
  end
  local different=state and (not ctx or ctx.path~=state.path or ctx.world~=state.world or ctx.creative~=state.creative or ctx.documentGeneration~=state.documentGeneration or ctx.ownerGeneration~=state.ownerGeneration)
  if different then
   if X.ModSync and (tokenCurrent(state.documentToken)) then X.ModSync.publish(state.gm,state.level,{},state.documentToken) end
   if not restoreSettled(state) then return end
    if tools.reset()==false then return end
    state=nil
  end
  if ctx and not state then
   state=ctx
   local ok,err=pcall(load,state)
   if not ok then state.error=tostring(err); log('load refused: '..state.error) end
   if X.ModSync then
    if not state.error then publish(state,state.desired)end
    X.ModSync.warn(state.gm,state.path)
   end
  end
  if state and state.busy or clientState and clientState.busy then return end
  local request=table.remove(queue,1)
  if not request and pendingAim and state and state.creative then
   if state.error then cancelAim();log('Home refused: '..tostring(state.error))
   else request={args={'aim'},chat=true,key=true,aim=pendingAim} end
  end
  local function execute()
   if request.aim then
    local intent=request.aim
    if pendingAim~=intent or intent.world~=aimWorld() or intent.epoch~=X.Lifetime.epoch or intent.session~=aimSession or X.Lifetime.transition or not C.CreativeMaps then return end
    pendingAim=nil
   end
   if X.command and not request.key then X.command(run,state,request.args,request.chat) -- hotkeys: no modal dialog
   else
    local ok,err=pcall(run,state,request.args,request.chat)
    if not ok then log('command refused: '..tostring(err)) end
   end
  end
  if request then
   if X.work then
    commandPending=true
    X.work.submit('hide command','scenery command',function()
     commandPending=false;execute()
     if api.invalidate then api.invalidate() end
     if X.wake then X.wake() end
     return true
    end)
   else execute() end
  end
  if state and X.ModSync and not state.error and not state.busy then publish(state,state.desired) end
 end
  local ownershipEpoch=X.Lifetime.epoch
  function api.abandon()
   -- Epoch teardown owns Native restoration/destruction. Drop only Lua state.
   cancelAim()
   if X.work then X.work.cancel('hide transaction');X.work.cancel('hide command') end
   state=nil;clientState=nil;queue={};commandPending=false;inventories={};contextCache=nil;pendingRestores={}
   tools.abandon();ownershipEpoch=X.Lifetime.epoch
   return true
  end
  function api.cleanup()
   if X.Lifetime.transition or ownershipEpoch~=X.Lifetime.epoch then return api.abandon() end
   local toolsDone,why=tools.cleanup(state)
   restoreRevision=restoreRevision+1 -- explicit retry only; no new scheduler
   if toolsDone==false then return false,why end
   return api.reset() -- original backend snapshots are part of the same owned cleanup
  end
  function api.reset()
   if X.Lifetime.transition or ownershipEpoch~=X.Lifetime.epoch then return api.abandon() end
   cancelAim()
   if X.work then X.work.cancel('hide transaction');X.work.cancel('hide command') end
   -- Failed blink rollback retains both its original context and backend ownership.
   local done,why=tools.reset();if done==false then return false,why end
   rememberRestore(state);rememberRestore(clientState)
   state=nil;clientState=nil;queue={};commandPending=false;inventories={};contextCache=nil
  return retryRestores()
  end
  X.Lifetime.onReset(function() Files.clear();api.abandon() end)
 function api.actorClaimed(scope,path)
  if not state or state.worldKey~=scope.world_key or state.worldGeneration~=scope.world_generation or state.epoch~=scope.core_epoch then return false end
  for _,set in ipairs({state.applied or {},state.desired or {}})do
   for key in pairs(set)do if key:match('^%S+ (.+)$')==path then return true end end
  end
  return false
 end
 D.on_change(function(v,reason)
  if state and v and reason=='native manual target' and v.owner_generation==state.ownerGeneration
   and v.document_generation==state.documentGeneration and v.world_key==state.worldKey
   and v.world_generation==state.worldGeneration and v.core_epoch==(state.coreEpoch or state.epoch) then
   local token,current=D.capture()
   if token and D.current(token) and current.publication_revision==v.publication_revision then
    state.documentToken=token;state.path=v.target_path;state.documentName=v.name;state.documentKind=v.document_kind
   end
  end
  if api.invalidate then api.invalidate() end
  if X.wake then X.wake() end
 end)
 X.hook('Suppression',X.CREATIVE,'B_CreativeGameState','LoadLayoutMulticast',cancelAim) -- intent only; completed-load binding belongs to Core publisher
 X.hook('Suppression',X.CREATIVE,'B_CreativeGameMode','NewLayout',cancelAim)
 X.hook('Suppression','/Game/Blueprints/Core/','B_GameMode','LoadPropLayoutFromSaveGame',function() end)
 X.cachedPoll(api,function() return #queue>0 or pendingAim~=nil end)
 X.Suppression=api
 return api
end
return M
