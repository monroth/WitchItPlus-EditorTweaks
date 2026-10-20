-- Event-driven native Blueprint teleporter adapter. No gameplay Tick, trace loop,
-- manual pawn movement, Teleport invocation, or overlap-handler replacement.
local dir=assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))
local Store=dofile(dir..'teleporter_store.lua')
local Scenery=dofile(dir..'scenery.lua')
local M={CLASS='/Game/Blueprints/StaticProps/B_TeleporterZone.B_TeleporterZone_C'}
local function colon(key) return key and key:gsub('|',':',1) end
local function key(o) return tostring(o:GetAddress())..'|'..o:GetFullName() end
local function valid(o) return o and o:IsValid() and not o:IsActorBeingDestroyed() end
function M.document(X)
 for k,gm in pairs(X.Registry.buckets.B_CreativeGameMode_C or {}) do
  if not X.Lifetime.retired[k] and valid(gm) and not gm:GetFullName():find('Default__',1,true) then
   local world=gm:GetWorld()
   if world and world:IsValid() and (not X.Lifetime.world or colon(key(world))==X.Lifetime.world) then
    local name=gm.LoadedLayoutName;name=type(name)=='string' and name or name:ToString()
    local statics=StaticFindObject('/Script/Engine.Default__GameplayStatics')
    local level=statics:GetCurrentLevelName(gm,true);level=type(level)=='string' and level or level:ToString()
    return {actor_key=key(gm),world_key=key(world),core_epoch=X.Lifetime.epoch,
     role='host',world=level,name=name,document_kind=name=='' and 'unsaved' or 'saved'}
   end
  end
 end
 error('current Creative game mode unavailable')
end
function M.document_current(X,v)
 local gm=X.Registry.buckets.B_CreativeGameMode_C and X.Registry.buckets.B_CreativeGameMode_C[colon(v.actor_key)]
 if not valid(gm) or key(gm)~=v.actor_key or key(gm:GetWorld())~=v.world_key then return false end
 local name=gm.LoadedLayoutName;name=type(name)=='string' and name or name:ToString()
 return name==(v.name or '')
end
function M.new(X,document,held)
 X.teleporterScope=X.teleporterScope or assert(X.api.Native.scope(X.api.id),'Native scope unavailable')
 local E=X.teleporterScope
 local N={}
 local function check() assert(held(),'teleporter document retired') end
 local G={current=held}
 function G.valid(o) return o~=nil and o:IsValid() and (not o:IsA('/Script/Engine.Actor') or not o:IsActorBeingDestroyed()) end
 function G.key(o) if G.valid(o) then return tostring(o:GetAddress())..':'..o:GetFullName() end end
 function G.worldKey(o) return G.valid(o) and G.key(o:GetWorld()) or nil end
 function G.authority(o) return G.valid(o) and o:HasAuthority()==true end
 function G.call(o,k,...) return o[k](o,...) end
 function G.text(o) return type(o)=='string' and o or o:ToString() end
 local function read(o,k) return o[k] end
 local call=G.call
 local function set(o,k,v) o[k]=v end
 local function vector(v,fields)
  local r={};for _,k in ipairs(fields or {'X','Y','Z'}) do r[k]=read(v,k);assert(type(r[k])=='number','native numeric field unavailable') end;return r
 end
 local function valid(o) assert(G.valid(o),'native teleporter object invalid');return o end
 local function object(path) local o=StaticFindObject(path);assert(G.valid(o),'native teleporter object unavailable: '..path);return o end
 local function full(o) return call(o,'GetFullName') end
 local function record(o,path)
  valid(o);local key=G.key(o);assert(key,'native object unavailable')
  local world=G.worldKey(o);assert(world==colon(document.world_key),'wrong native teleporter world')
  local name=full(o);assert(not name:find('Default__',1,true),'CDO editing refused')
  local nativePath=name:match('^%S+ (.+)$');assert(nativePath,'native object path unavailable')
  return {actor=o,key=key,world=world,path=path or nativePath,name=name}
 end
 local function actor(r)
  check();assert(r and r.key,'teleporter actor unavailable')
  valid(r.actor);assert(G.key(r.actor)==r.key and G.worldKey(r.actor)==r.world,'teleporter identity changed');return r.actor
 end
 local function owned(a,field,class)
  local c=valid(read(a,field));assert(call(c,'IsA',class)==true,'wrong native teleporter component')
  assert(G.key(call(c,'GetOwner'))==G.key(a),'teleporter component owner changed');return c
 end
 local function scene(c)
  return {location=vector(read(c,'RelativeLocation')),rotation=vector(read(c,'RelativeRotation'),{'Pitch','Yaw','Roll'}),
   absoluteLocation=read(c,'bAbsoluteLocation'),absoluteRotation=read(c,'bAbsoluteRotation'),absoluteScale=read(c,'bAbsoluteScale')}
 end
 local function applyScene(c,v)
  assert(type(v.absoluteLocation)=='boolean' and type(v.absoluteRotation)=='boolean' and type(v.absoluteScale)=='boolean','native transform flags unavailable')
  for k,n in pairs(v.location) do set(read(c,'RelativeLocation'),k,n) end
  for k,n in pairs(v.rotation) do set(read(c,'RelativeRotation'),k,n) end
  -- Boolean-only transform refresh avoids FHitResult OUT marshaling.
  call(c,'SetAbsolute',not v.absoluteLocation,not v.absoluteRotation,v.absoluteScale)
  call(c,'SetAbsolute',v.absoluteLocation,v.absoluteRotation,v.absoluteScale)
 end
 local function point(p) return {location={X=p.X,Y=p.Y,Z=p.Z},rotation={Pitch=0,Yaw=p.Yaw,Roll=0},absoluteLocation=true,absoluteRotation=true,absoluteScale=false} end
 function N.current() return G.current() end
 function N.retired(r)return r and not G.valid(r.actor) or false end
 function N.context(edit)
  check()
  local key=colon(document.actor_key)
  local gm=X.Registry.buckets.B_CreativeGameMode_C and X.Registry.buckets.B_CreativeGameMode_C[key]
  assert(gm and G.key(gm)==key and G.worldKey(gm)==colon(document.world_key),'Creative GM unavailable')
  assert(call(gm,'IsA','/Game/Blueprints/Gamemodes/CreativeMode/B_CreativeGameMode.B_CreativeGameMode_C') and G.authority(gm),'Creative host required')
  -- Creative uses ?listen even alone. Require one actual player plus local
  -- authority on every operation; this editor has no peer edit transport.
  assert(call(gm,'GetNumPlayers')==1,'teleporter editing supports a single-player host only')
  -- Resolve the actual local player directly. A package's background scenery
  -- inventory may not have reached PlayerController yet after Core re-enable.
  local statics=object('/Script/Engine.Default__GameplayStatics')
  local pc=call(statics,'GetPlayerController',gm,0)
  assert(G.valid(pc) and G.worldKey(pc)==colon(document.world_key)
   and G.call(pc,'IsLocalController')==true and G.authority(pc),'local Creative host controller required')
  check()
  if edit then
   local gs=valid(call(statics,'GetGameState',gm));assert(read(gs,'IsPlayTestMode')==false,'leave playtest before editing teleporters')
  end
  return gm
 end
 function N.catalog()
  N.context(false);local found=X.api.find_all('B_TeleporterZone_C')
  local loaded=type(EObjectFlags)=='table' and (EObjectFlags.RF_WasLoaded or EObjectFlags.WasLoaded)
  assert(type(loaded)=='number','baked teleporter origin flag unavailable')
  local catalog,refs={},{}
  for _,a in ipairs(found or {}) do
   if G.valid(a) and G.worldKey(a)==colon(document.world_key) then
    local wasLoaded=G.call(a,'HasAnyFlags',loaded);assert(type(wasLoaded)=='boolean','native loaded-origin query unavailable')
    if wasLoaded then
    assert(full(call(a,'GetClass')):match('^%S+ (.+)$')==M.CLASS,'unverified teleporter subclass')
    local r=record(a);local id='b:'..r.path;assert(not catalog[id],'duplicate baked teleporter path')
    local s=N.snapshot(r);local entry=vector(call(a,'K2_GetActorLocation'));entry.Yaw=read(call(a,'K2_GetActorRotation'),'Yaw')
    local target=owned(a,'TargetLocation','/Script/Engine.SceneComponent')
    local exit=vector(call(target,'K2_GetComponentLocation'));exit.Yaw=read(call(target,'K2_GetComponentRotation'),'Yaw')
    catalog[id]={id=id,baked=r.path,removed=not s.actorCollision or s.zoneCollision==0 or not s.overlap,
     entry=entry,exit=exit,extent=s.extent,effects=s.effects,transferVelocity=s.transferVelocity,velocity=s.velocity,decor={}}
    refs[id]=r
    end
   end
   check()
  end
  return catalog,refs
 end
 function N.snapshot(r)
  local a=actor(r);local zone=owned(a,'Zone','/Script/Engine.BoxComponent');local target=owned(a,'TargetLocation','/Script/Engine.SceneComponent')
  -- Read the authored body setting, not effective GetCollisionEnabled (which
  -- can report NoCollision while the owning actor is temporarily disabled).
  local s={hidden=read(a,'bHidden'),actorCollision=read(a,'bActorEnableCollision'),zoneCollision=read(read(zone,'BodyInstance'),'CollisionEnabled'),
   overlap=call(zone,'GetGenerateOverlapEvents'),extent=vector(call(zone,'GetUnscaledBoxExtent')),target=scene(target),
   effects=read(a,'UseEffects'),transferVelocity=read(a,'TransferPropVelocity'),velocity=read(a,'ExitVelocityMultiplier')}
  assert(type(s.hidden)=='boolean' and type(s.actorCollision)=='boolean' and type(s.overlap)=='boolean','native trigger flags unavailable')
  assert(type(s.zoneCollision)=='number' and s.zoneCollision%1==0 and s.zoneCollision>=0 and s.zoneCollision<=5,'native collision enum unavailable')
  if r.created then s.root=scene(owned(a,'DefaultSceneRoot','/Script/Engine.SceneComponent')) end
  return s
 end
 function N.quiesce(r)
  local a=actor(r);local z=owned(a,'Zone','/Script/Engine.BoxComponent')
  call(z,'SetGenerateOverlapEvents',false);call(z,'SetCollisionEnabled',0);call(a,'SetActorEnableCollision',false)
 end
 local function extent(z,e)
  local v=call(z,'GetUnscaledBoxExtent') -- actual native FVector value, never a constructed Lua struct
  for k,n in pairs(e) do set(v,k,n) end;call(z,'SetBoxExtent',v,false)
 end
 function N.configure(r,row,destination,baseline,targetChanged)
  local a=actor(r);local z=owned(a,'Zone','/Script/Engine.BoxComponent');local t=owned(a,'TargetLocation','/Script/Engine.SceneComponent')
  if r.created then
   X.api.shared('Core').teleporter_zone.configure(a,row.entry,destination,row)
  else
   applyScene(t,not targetChanged and baseline.target or point(destination));extent(z,row.extent)
   set(a,'UseEffects',row.effects);set(a,'TransferPropVelocity',row.transferVelocity);set(a,'ExitVelocityMultiplier',row.velocity)
  end
 end
 function N.activate(r,row,baseline)
  local a=actor(r);local z=owned(a,'Zone','/Script/Engine.BoxComponent')
  call(a,'SetActorHiddenInGame',row.removed or baseline.hidden)
  call(a,'SetActorEnableCollision',not row.removed and baseline.actorCollision)
  call(z,'SetCollisionEnabled',row.removed and 0 or baseline.zoneCollision)
  call(z,'SetGenerateOverlapEvents',not row.removed and baseline.overlap) -- last: native BeginOverlap may reenter
 end
 function N.restore(r,s)
  N.quiesce(r);local a=actor(r);local z=owned(a,'Zone','/Script/Engine.BoxComponent')
  applyScene(owned(a,'TargetLocation','/Script/Engine.SceneComponent'),s.target);extent(z,s.extent)
  if s.root then applyScene(owned(a,'DefaultSceneRoot','/Script/Engine.SceneComponent'),s.root) end
  set(a,'UseEffects',s.effects);set(a,'TransferPropVelocity',s.transferVelocity);set(a,'ExitVelocityMultiplier',s.velocity)
  call(a,'SetActorHiddenInGame',s.hidden);call(a,'SetActorEnableCollision',s.actorCollision)
  call(z,'SetCollisionEnabled',s.zoneCollision);call(z,'SetGenerateOverlapEvents',s.overlap)
 end
 function N.spawn(row,retain)
  local gm=N.context(true);local cls,why=E.load_class(M.CLASS,gm);assert(cls,why or 'native teleporter class unavailable: '..M.CLASS)
  local defaults=valid(call(cls,'GetCDO'));local defaultCollision=read(defaults,'bActorEnableCollision');local defaultHidden=read(defaults,'bHidden')
  assert(type(defaultCollision)=='boolean' and type(defaultHidden)=='boolean','cooked actor defaults unavailable')
  local a=assert(E.spawn(cls,gm,row.entry,function(actor)
   actor:SetActorEnableCollision(false);actor:SetReplicates(false)
  end),'native teleporter spawn failed')
  local r={actor=a,created=true};retain(r)
  for k,v in pairs(record(a)) do r[k]=v end
  local baseline=N.snapshot(r)
  -- Deferred actor collision was deliberately disabled; native Zone defaults are retained.
  baseline.actorCollision=defaultCollision;baseline.hidden=defaultHidden;r.baseline=baseline
  N.quiesce(r);return r
 end
 function N.destroy(r)
  if N.retired(r) then return true end
  local ok,why=E.destroy(actor(r));return assert(ok,why or 'native teleporter destruction failed')
 end
 local bridge={call=call,read=read,text=function(v)return G.text(v)end,
  H={valid=function(v)return G.valid(v)end},check=check,same=function(a,b)return G.key(a)==G.key(b)end}
 function N.decor(path)
  local a=object(path);local r=record(a,path)
  assert(Scenery.eligible(bridge,a,full(a)),'decoration must be explicitly eligible scenery; ship/gameplay actors refused')
  return r
 end
 function N.snapshotDecor(r)
  local a=actor(r);local effect=Scenery.snapshot(bridge,a)
  if effect.component then effect.componentKey=G.key(effect.component);assert(effect.componentKey,'decoration component identity unavailable')end
  return {hidden=read(a,'bHidden'),collision=read(a,'bActorEnableCollision'),effect=effect}
 end
 function N.hideDecor(r,s)
  local a=actor(r);call(a,'SetActorHiddenInGame',true);call(a,'SetActorEnableCollision',false);Scenery.hide(bridge,a,s.effect,check)
 end
 function N.restoreDecor(r,s)
  local a=actor(r);local live=Scenery.snapshot(bridge,a)
  if s.effect.component then
   assert(live.field==s.effect.field and G.key(live.component)==s.effect.componentKey,'decoration component role changed')
  else assert(not live.component,'decoration component role changed')end
  -- Restore through the freshly admitted current field, never an old component wrapper.
  local restore={component=live.component,field=s.effect.field,visible=s.effect.visible,playing=s.effect.playing,active=s.effect.active}
  Scenery.restore(bridge,a,restore,false,check);call(a,'SetActorHiddenInGame',s.hidden);call(a,'SetActorEnableCollision',s.collision)
 end
 function N.sameSnapshot(a,b)
  -- Effect snapshots contain an exact component reference, compared by admitted identity.
  local function effect(s)
   if s.effect and s.effect.component then
    local r=Store.copy({hidden=s.hidden,collision=s.collision,effect={field=s.effect.field,visible=s.effect.visible,active=s.effect.active,playing=s.effect.playing}})
    r.effect.key=s.effect.componentKey;return r
   end
   return s
  end
  return Store.equal(effect(a),effect(b))
 end
 return N
end
return M
