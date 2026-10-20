-- Ship files observe native IO independently of geometry and catalog.
local M={contract='Core.Native.ScalarStorage/v1'}
local dir=assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))
local T=dofile(dir..'ship_topology.lua')
local Codec=dofile(dir..'ship_codec.lua')
function M.new(deps)
 local D,IO,F=deps.document,deps.io,deps.files
 local alive=true;local clients={};local saves={};local pending,errorText
 local function live()return alive and deps.current()==true end
 local function view()local token,v=D.capture();if token and D.current(token)then return v end end
 local function read(v)
  local bytes=IO.read(v.target_path..'.shipparts',65536)
  return bytes and Codec.decode(T,T.world,v.name,bytes)or {}
 end
 local function request(e)
  pending={event={owner_key=e.owner_key or e.actor_key,name=e.name,target_path=e.target_path,world=e.world}};errorText=nil
 end
 local function incoming()
  assert(pending and not pending.error,pending and pending.error)
  if not pending.rows then pending.rows=read(pending.event)end
  return pending.rows
 end
 local function snapshot()
  local v=view()
  if not v or v.world~='PirateIsland'then return end
  if pending then return {rows=incoming(),revision=0,document=v}end
  for c in pairs(clients)do if c.current()and c.hooks then
   local h,rows,revision=c.hooks.capture(v)
   assert(h and rows,'ship edits busy or unapplied; companion preserved')
   return {rows=rows,revision=revision,document=v,client=c,hooks=c.hooks,capture=h}
  end end
  return {rows=v.target_path and read(v)or {},revision=0,document=v}
 end
 local function publish(s,e)
  local bytes=Codec.encode(T,T.world,e.name,s.rows)
  local ok,why=IO.writeBytes(e.target_path..'.shipparts',bytes,live,e.serial,false)
  assert(ok,why);assert(IO.read(e.target_path..'.shipparts',65536)==bytes,'ship readback differs')
  if s.client and s.client.current()and s.client.hooks==s.hooks then
   assert(s.hooks.finalize(s.capture,s.rows,s.revision,e.autosave and 'recovery'or 'manual',view()),'ship saved state unavailable')
  end
  if pending and not e.autosave then pending.unpublished=false end
  errorText=nil;deps.log('ShipFiles: saved '..e.target_path..'.shipparts')
 end
 local stop=F.observe(function(e,existing)
  if not live()then return end
  if existing then if e.world=='PirateIsland'then request(e)end;return end
  if e.kind=='load'and e.complete and e.success then
   if e.world=='PirateIsland'then request(e)else pending=nil end
  elseif e.kind=='save'then
   if e.phase=='entry'then
    local ok,s=pcall(snapshot)
    if ok then saves[e.serial]=s else errorText=tostring(s);deps.log('ShipFiles: snapshot failed; companion preserved: '..errorText)end
   elseif e.complete then
    local s=saves[e.serial];saves[e.serial]=nil
    if e.success and s and s.document.actor_key==e.owner_key then
     if not e.autosave then
      if pending then pending.unpublished=true;pending.delivered=nil end
      for c in pairs(clients)do if c.current()and c.hooks then c.hooks.failed(nil,'manual')end end -- follows actual name even if publication fails
     end
     local ok,why=pcall(publish,s,e)
     if not ok then errorText=e.target_path..'.shipparts: '..tostring(why)..'; save again to retry';deps.log('ShipFiles: '..errorText)end
    end
   end
  end
 end,true)
 local S={contract=M.contract,current=live,operation_current=live}
 function S.poll()
  local p=pending;if not live()or not p or p.error or p.delivered then return end
  local v=view();if not v or v.actor_key~=p.event.owner_key or v.world~='PirateIsland'then return end
  local ok,why=pcall(function()
   local rows=incoming();local text=Codec.encode(T,T.world,v.name,rows)
   for c in pairs(clients)do if c.current()and c.loaded then c.loaded(v,text,p.unpublished==true);p.delivered=true end end
  end)
  if not ok then p.error=p.event.target_path..'.shipparts: '..tostring(why)..'; use shiphide load to retry';errorText=p.error;deps.log('ShipFiles: '..p.error)end
 end
 function S.attach(api,current)
  local c={current=current};clients[c]=true
  local tickets={};local C={contract=M.contract,current=function()return clients[c]and live()and current()or false end}
  C.operation_current=C.current
  function C.bind_session(hooks)c.hooks=hooks;return function()if c.hooks==hooks then c.hooks=nil end end end
  function C.capture(v,g)assert(C.current()and g());local h={};tickets[h]=v;return h end
  function C.read(h,g)
   local v=assert(tickets[h]);assert(C.current()and g())
   -- Explicit reload retries the unread original after a failed Save As.
   if pending then pending.error=nil;pending.delivered=nil;local rows=incoming();pending.delivered=true;return Codec.encode(T,T.world,v.name,rows),pending.unpublished==true end
   return IO.read(v.target_path..'.shipparts',65536)
  end
  function C.write(h,text,revision,g)
   local v=assert(tickets[h]);assert(C.current()and g());assert(not pending,'ship companion unapplied; use shiphide load')
   local rows=Codec.decode(T,T.world,v.name,text)
   local ok,why=IO.writeBytes(v.target_path..'.shipparts',text,function()return C.current()and g()end,revision,false);assert(ok,why)
   errorText=nil
   return {contract='Core.Native.ScalarStorage.Receipt/v1',publication='COMMITTED',world=T.world,layout=v.name,target_path=v.target_path,
    document_generation=v.document_generation,owner_generation=v.owner_generation,document_revision=v.revision,revision=revision,bytes=text}
  end
  function C.on_load(fn)
   c.loaded=fn
   if not pending then local v=view();if v and v.world=='PirateIsland'and v.target_path then request(F.current(v.actor_key)or v)end end
   S.poll();return function()if c.loaded==fn then c.loaded=nil end end
  end
  function C.applied()if pending and pending.delivered then local dirty=pending.unpublished;pending=nil;if not dirty then errorText=nil end end end
  function C.error()return errorText end
  function C.blocked()return pending and pending.error end
  function C.release(h)tickets[h]=nil end
  local function close()clients[c]=nil;return true end;api.own(close,close)
  return C
 end
 function S.retire()alive=false;clients={};saves={};pending=nil;stop();return true end
 return S
end
return M
