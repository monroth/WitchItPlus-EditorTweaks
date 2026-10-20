-- Protocol 2: common Core readiness owns admission; native bodies still run first.
-- File payload semantics remain FAPP_HIDDEN_V1. Wire identity is exact saved document data.
local M={VERSION=2,BYTES=384,BODY_LIMIT=300000,LIMIT=308400,PARTS=804}
local PREFIX='BWPMS2:'
local DATA='BWPMS2_DATA_V1:'
local function hex(s) return (s:gsub('.',function(c) return string.format('%02x',c:byte()) end)) end
local function unhex(s) return (s:gsub('%x%x',function(c) return string.char(tonumber(c,16)) end)) end
local function integer(v,min,max) return type(v)=='number' and v%1==0 and v>=min and v<=max end
local function exact(s) return type(s)=='string' and #s>0 and #s<=4096 end
function M.chunks(text)
 assert(type(text)=='string' and #text>0 and #text<=M.LIMIT,'invalid suppression transfer')
 local pieces={};for i=1,#text,M.BYTES do pieces[#pieces+1]=hex(text:sub(i,i+M.BYTES-1)) end;return pieces
end
function M.assemble(holder,rev,i,total,data)
 if not integer(rev,1,2147483647) or not integer(total,1,M.PARTS) or not integer(i,1,total)
  or type(data)~='string' or #data==0 or #data>M.BYTES*2 or #data%2~=0 or not data:match('^%x+$') then return end
 if rev<=(holder.received or 0) then return end
 local t=holder.transfer
 if t and rev<t.revision then return end
 if not t or rev>t.revision then t={revision=rev,total=total,parts={},count=0};holder.transfer=t end
 if t.total~=total then holder.transfer=nil;return end
 if t.parts[i] then if t.parts[i]~=data then holder.transfer=nil end;return end
 t.parts[i]=data;t.count=t.count+1
 if t.count~=total then return end
 holder.transfer=nil
 local raw=unhex(table.concat(t.parts));if #raw<=M.LIMIT then return raw end
end
function M.pack(fact,body)
 assert(fact.document_kind=='saved' and exact(fact.world) and exact(fact.name),'saved document required')
 assert(integer(fact.generation,1,2147483647) and integer(fact.revision,0,2147483647),'invalid document version')
 assert(type(body)=='string' and #body<=M.BODY_LIMIT,'invalid suppression body')
 return DATA..#fact.world..':'..#fact.name..':'..fact.generation..':'..fact.revision..'\n'..fact.world..fact.name..body
end
function M.unpack(raw)
 if type(raw)~='string' or #raw>M.LIMIT then return end
 local w,n,g,r,offset=raw:match('^'..DATA..'(%d+):(%d+):(%d+):(%d+)\n()')
 w,n,g,r=tonumber(w),tonumber(n),tonumber(g),tonumber(r)
 if not integer(w,1,4096) or not integer(n,1,4096) or not integer(g,1,2147483647) or not integer(r,0,2147483647) then return end
 if #raw<offset+w+n or #raw-(offset+w+n)+1>M.BODY_LIMIT then return end
 return {document_kind='saved',world=raw:sub(offset,offset+w-1),name=raw:sub(offset+w,offset+w+n-1),generation=g,revision=r},raw:sub(offset+w+n)
end
local function fact(snapshot)
 if type(snapshot)~='table' or snapshot.document_kind~='saved' or not exact(snapshot.world) or not exact(snapshot.name) then return end
 local g=snapshot.role=='client' and snapshot.source_generation or snapshot.document_generation
 local r=snapshot.role=='client' and snapshot.source_revision or snapshot.revision
 if not integer(g,1,2147483647) or not integer(r,0,2147483647) then return end
 return {document_kind='saved',world=snapshot.world,name=snapshot.name,generation=g,revision=r}
end
local function same(a,b)
 return a and b and a.document_kind==b.document_kind and a.world==b.world and a.name==b.name and a.generation==b.generation and a.revision==b.revision
end
local function scope(view)
 return table.concat({view.pc_key,view.local_session,view.remote_session,view.local_revision,view.remote_revision},'|')
end
function M.init(X)
 local owner=X.api
 local Core=assert(owner.shared('Core'),'Core 2 required')
 local Sync=assert(Core.package_sync,'common Core readiness required')
 local D=assert(owner.map_document,'central document service required')
 local Work=assert(X.work or X.Work,'finite Core work required')
 local L=X.Lifetime
 local dir=assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))
 local Suppression=dofile(dir..'maps_suppression.lua')
 
 local api={};local roster,active,snapshot,receive
 local jobs={};local sent={};local serial,revision=0,0;local latest
 local function live() return owner.is_live() and not L.transition end
 local function enabled() return true end
 local function finish(r,state,reason)
  if r.closed then return true end
  r.closed=true;if jobs[r.key]==r then jobs[r.key]=nil end
  r.state=state;if state~='completed' and sent[r.scope]==r then sent[r.scope]=nil end
  if not latest or r.serial>=latest.serial then latest={serial=r.serial,state=state,reason=reason,revision=r.revision,pc_key=r.view.pc_key} end
  r.pieces=nil;r.token=nil;r.view=nil;r.work=nil
  return true
 end
 local function ownsWork(r) return r.work~=nil and Work.keys[r.key]==r.work end
 local function cancelOwned(r)
  if owner.is_live() and ownsWork(r) then pcall(Work.cancel,r.key) end
 end
 local function cancelJobs(reason)
  local old=jobs;jobs={}
  for _,r in pairs(old) do
   cancelOwned(r);finish(r,'retired',reason)
  end
 end
 local function clear(reason)
  local changed=active~=nil or snapshot~=nil or receive~=nil or next(jobs)~=nil
  active=nil;snapshot=nil;receive=nil;sent={};revision=0
  cancelJobs(reason)
  if changed then X.revision=X.revision+1 end
 end
 local function current(r)
  return not r.closed and live() and enabled() and D.current(r.token) and Sync.current(r.view)
 end
 local function sendTo(view)
  if not active or not live() or not enabled() or not D.current(active.token) or not Sync.current(view) then return false,'retired' end
  local id=scope(view)
  local previous=sent[id]
  if previous and previous.revision==active.revision then
   if previous.state=='completed' or ownsWork(previous) then return true,'unchanged' end
   finish(previous,'cancelled','work_cancelled')
  end
  serial=serial+1
  local r={serial=serial,key='bwp-map-state:'..serial,scope=id,token=active.token,view=view,pieces=active.pieces,index=1,revision=active.revision}
  jobs[r.key]=r
  local function step()
   if not current(r) then return finish(r,'retired','owner_or_document_changed') end
   if r.index>#r.pieces then return finish(r,'completed','sent') end
   return {native=function()
    if not current(r) then finish(r,'retired','owner_or_document_changed');return end
    local i=r.index;r.index=i+1 -- consume before the external call/reentry
    local v=r.view
    local text=PREFIX..'STATE:'..v.local_session..':'..v.remote_session..':'..v.local_revision..':'..v.remote_revision..':'..r.revision..':'..i..':'..#r.pieces..':'..r.pieces[i]
    local ok,result,reason=pcall(Sync.send,owner,v.pc_key,text,v)
    if not ok then finish(r,'failed','action_error');error(result,0) end
    if r.closed then return end
    if not result then finish(r,'failed',reason or 'send_rejected')
    elseif not current(r) then finish(r,'retired','owner_or_document_changed')
    elseif r.index>#r.pieces then finish(r,'completed','sent') end
   end}
  end
  local ok,result=pcall(Work.submit,r.key,'BaseWorldPlus suppression RPC',step)
  local record=Work.keys[r.key];if record and record.step==step then r.work=record end
  if not ok then cancelOwned(r);finish(r,'failed','schedule_error');error(result,0) end
  if result==false then finish(r,'failed','schedule_rejected');return false,'schedule_rejected' end
  if not r.closed then sent[id]=r elseif r.state=='completed' then sent[id]=r end
  return true,'accepted'
 end
 local function fanout()
  if not roster or not roster.ready or roster.host~=true or not active then return true,'stored' end
  local state='unchanged'
  for _,row in ipairs(roster.peers) do
   local view=Sync.peer(row.pc_key)
   if view then local ok,reason=sendTo(view);if not ok then return false,reason end;if reason=='accepted' then state='accepted' end end
  end
  return true,state
 end
 function api.publish(ctx,level,set,heldToken)
  if not live() or not enabled() then return false,'inactive' end
  if not heldToken then return false,'document_unbound' end
  if not D.current(heldToken) then return false,'retired' end
  local _,document=D.capture();local token=heldToken;local identity=fact(document)
  if not identity or document.role~='host' then return false,'document_unbound' end
  if level~=identity.world then return false,'world_mismatch' end
  -- The token is checked before reflection, and again after native owner checks.
  if not D.current(token) then return false,'retired' end
  if not X.live(ctx) then return false,'foreign_owner' end
  if not live() or not D.current(token) then return false,'retired' end
  if not X.H.authority(ctx) then return false,'foreign_owner' end
  if not live() or not D.current(token) then return false,'retired' end
  if L.worldKey(ctx)~=L.world then return false,'foreign_owner' end
  if not live() or not D.current(token) then return false,'retired' end
  local body=Suppression.encode(level,set)
  local raw=M.pack(identity,body)
  if active and active.text==raw and D.current(active.token) then return fanout() end
  cancelJobs('superseded_publication');sent={}
  revision=revision+1
  active={token=token,identity=identity,text=raw,pieces=M.chunks(raw),revision=revision}
  return fanout()
 end
 function api.clientSnapshot()
  if not live() or not enabled() then clear('inactive');return end
  if snapshot and (not D.current(receive.token) or not Sync.current(receive.view)) then snapshot=nil;receive=nil end
  return snapshot
 end
 function api.upstream() end -- old HELLO/announces never authorize protocol 2
 function api.downstream(self,value)
  if not live() or not enabled() then return end
  local text=X.text(X.get(value))
  if #text>900 or text:sub(1,#PREFIX)~=PREFIX then return end
  local ss,ts,sr,tr,rev,i,n,data=text:sub(#PREFIX+1):match('^STATE:([%x%-]+):([%x%-]+):(%d+):(%d+):(%d+):(%d+):(%d+):(%x+)$')
  if not ss then return end
  local pc=X.get(self)
  local view=Sync.accept(pc,ss,ts,tonumber(sr),tonumber(tr))
  if not view or view.host~=false then return end
  local token,document=D.capture();local identity=fact(document)
  if not token or not identity or document.role~='client' or not D.current(token) then return end
  local id=scope(view)
  if not receive or receive.scope~=id or not D.current(receive.token) then
   receive={scope=id,view=view,token=token};snapshot=nil
  end
  local raw=M.assemble(receive,tonumber(rev),tonumber(i),tonumber(n),data)
  if not raw then return end
  local wire,body=M.unpack(raw)
  if not same(wire,identity) or not D.current(token) or not Sync.current(view) then return end
  local ok,set=pcall(Suppression.decode,body,identity.world)
  if not ok then X.log('ModSync','suppression body rejected');return end
  if not live() or not D.current(token) or not Sync.current(view) or receive.scope~=id then return end
  receive.received=tonumber(rev)
  snapshot={gm=pc,level=identity.world,world=L.world,name=identity.name,document_generation=identity.generation,
   document_revision=identity.revision,desired=set,revision=tonumber(rev),session=id..'|document:'..identity.generation..':'..identity.revision}
  X.revision=X.revision+1
 end
 function api.everyoneModded()
  if not live() or not roster or not roster.ready or not roster.host or roster.overflow then return false end
  for _,p in ipairs(roster.peers) do if not p.compatible or not Sync.peer(p.pc_key) then return false end end
  return true
 end
 function api.unmodded()
  local result={}
  if not live() or not roster then return result end
  for _,p in ipairs(roster.peers) do
   if not p.compatible or not Sync.peer(p.pc_key) then result[#result+1]={id=p.pc_key,name=p.display_name or 'Unknown player',modded=false,status=p.status} end
  end
  table.sort(result,function(a,b) return a.id<b.id end);return result
 end
 api.mapRequiresMod=X.mapRequiresMod
 function api.warn(ctx,layout,gi)
  if not live() or not roster or not roster.host or not X.mapRequiresMod(layout,gi) then return end
  if not X.live(ctx) or not X.H.authority(ctx) or L.worldKey(ctx)~=L.world then return end
  local names={};for _,p in ipairs(api.unmodded()) do names[#names+1]=p.name end
  if roster.overflow then names[#names+1]='additional players awaiting endpoint admission' end
  if #names>0 then X.message(ctx,'Some players need to update Editor tweaks. Compare mods in the Mods menu.') end
 end
 function api.begin() end -- native endpoint/roster admission belongs to Core
 function api.pending() return false end
 function api.poll() end -- compatibility entrypoint; no network producer or timed checks
 function api.status()
  local emit=X.queueReply or X.log
  emit('ModSync',api.everyoneModded()and 'All players have matching mods.'or 'Some players have missing or outdated mods.')
  if roster then for _,p in ipairs(roster.peers) do emit('ModSync',(p.display_name or 'Player')..': '..(p.compatible and 'Mods match' or 'Mods differ')) end end
 end
 function api.outcome()
  if not owner.is_live() then clear('owner_retired')
  else
   for _,r in pairs(jobs) do
    if not current(r) then cancelOwned(r);finish(r,'retired','owner_or_document_changed')
    elseif not ownsWork(r) then finish(r,'cancelled','work_cancelled') end
   end
  end
  if latest then local copy={};for k,v in pairs(latest) do copy[k]=v end;return copy end
 end
 function api.reset() roster=nil;clear('reset') end
 L.onReset(api.reset)
 owner.own(api.reset,api.reset)
 Sync.observe(owner,function(value)
  if not live() then api.reset();return end
  roster=value
  local scopes={}
  for _,row in ipairs(roster.peers) do local v=Sync.peer(row.pc_key);if v then scopes[scope(v)]=true end end
  for id in pairs(sent) do if not scopes[id] then sent[id]=nil end end
  for _,r in pairs(jobs) do if not Sync.current(r.view) then cancelOwned(r);finish(r,'retired','session_changed') end end
  if receive and not Sync.current(receive.view) then receive=nil;snapshot=nil;X.revision=X.revision+1 end
  fanout()
 end)
 D.on_change(function() clear('document_changed') end,{replay=true})
 
 owner.hook('/Game/Blueprints/Player/B_PlayerController.B_PlayerController_C:ClientSetRevisionNumber',api.downstream,{finite_install=true})
 X.commandHandler('bwmodstatus',function() api.status();return true end)
 X.ModSync=api;return api
end
return M
