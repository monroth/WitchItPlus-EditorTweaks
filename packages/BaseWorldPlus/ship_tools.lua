-- Independent command UI; no shared /hide, Home or teleporter files are changed.
-- Native provider is REQUIRED. This package never substitutes raw UE4SS wrappers.
return function(api)
 local Core=assert(api.shared('Core'),'Core2 required')
 local T,C,Session=api.module('ship_topology'),api.module('ship_codec'),api.module('ship_session')

 local P,S,job,closing=nil,nil,nil,false
 local localProvider
 local pendingLoad,loadHook,afterJob
 local queue={}
 local function report(msg) api.log('shiphide '..tostring(msg)) end
 local function provider()
  local p=Core.capabilities.get('ship_components_native') or localProvider
  if not p and type(api.native_ship_parts)=='function' then
   local raw,store,owner=api.native_ship_parts()
   if raw then localProvider=api.module('ship_native_port').new(api,T,raw,store,owner);p=localProvider end
  end
  assert(type(p)=='table' and p.contract=='ShipParts.Native/v1','guarded component Native provider unavailable')
  for _,name in ipairs({'trace_ready','storage_ready','on_load','rebind','release'})do assert(type(p[name])=='function','complete ship binding missing '..name)end
  return p
 end
 local function session()
  local p=provider()
  if S then
   assert(P==p,'Native provider replaced; restore owned ship edits before rebinding')
   if not P.current(S.context,'edit') then P.rebind(S.context) end
   assert(P.current(S.context,'edit')==true,'ship document changed; old session requires cleanup/abandon')
   return S
  end
  local ctx=p.capture(T)
  assert(ctx~=nil and p.current(ctx,'edit')==true,'saved authoritative Creative layout required')
  P=p;S=Session.new(P,T,C,ctx);return S
 end
 local function subscribeLoad()
  local ok,p=pcall(provider);if not ok or loadHook or not p.storage_ready() then return end
  loadHook=p.on_load(function(view,text,dirty)pendingLoad={view=view,text=text,dirty=dirty} end)
 end
 local function resumeLoad()
  local payload=pendingLoad;if not payload then return end;local expected=payload.view or payload
  local token,v=api.map_document.capture()
  if not token or not v or not api.map_document.current(token) or v.target_path~=expected.target_path
   or v.document_generation~=expected.document_generation or v.owner_generation~=expected.owner_generation then
   pendingLoad=nil;report('reload discarded: coordinator document changed');return
  end
  if S then
   if P.current(S.context,'cleanup') then
    assert(S.cleanup(),'old component rollback pending');job=S.restore_all()
    afterJob=function()P.release(S.context);S.abandon();S=nil end;return
   end
   S.abandon();S=nil -- physical world/owner retired; no old getters or setters
  end
  local s=session();local text=payload.text or P.read_file(s.context,function()return P.current(s.context,'edit')end)
  if not text then pendingLoad=nil;report('no ship intent for loaded document');return end
  job=payload.text and s.change(C.decode(T,s.context.world,s.context.layout,text),{history=false,dirty=payload.dirty==true})or s.load(text);afterJob=function()if pendingLoad==payload then pendingLoad=nil;if P.file_applied then P.file_applied()end end;report('companion loaded into exact native components')end
 end
 local function run(words)
  local action=(words[1] or 'help'):lower()
  report('command '..table.concat(words,' '))
  if pendingLoad and pendingLoad.error and action~='load'and action~='status'and action~='help'then error(pendingLoad.error)end
  if action=='help' then
   report('list | target | hide <list-number> | show <list-number> | undo | save | load | cleanup | status')
   report('One complete mesh component per selection; hull mesh cannot be split into individual planks.');return
  elseif action=='status' then
   local p=Core.capabilities.get('ship_components_native') or localProvider
   local trace=false;if p and S then local ok,v=pcall(p.trace_ready,S.context,function()return p.current(S.context,'edit')end);trace=ok and v==true end
   report('Native='..tostring(p and p.contract)..'; active='..tostring(S~=nil)..'; dirty='..tostring(S and S.dirty==true)
    ..'; trace_ready='..tostring(trace)..'; storage_ready='..tostring(p and p.storage_ready and p.storage_ready()==true)
    ..'; error='..tostring(p and p.file_error and p.file_error())..'; cleanup_pending='..tostring(S and #S.pending or 0));return
  elseif action=='cleanup' then
   if S then assert(S.cleanup(),'component rollback pending');job=S.restore_all()else report('cleanup: no owned components')end;return
  end
  local p=provider()
  if action~='load'and p.file_blocked then assert(not p.file_blocked(),p.file_blocked())end
  local s=session()
  if action=='list' then
   s.lastList=s.list()
   report('list: '..#s.lastList..' eligible ship components')
   for i,r in ipairs(s.lastList) do report(i..'. '..r.component..(r.hull and ' [whole hull mesh]' or '')..(r.hidden and ' [hidden]' or '')) end
  elseif action=='target' then local key,d=s.pick();job=s.hide(key,d)
  elseif action=='hide' or action=='show' then
   local i=tonumber(words[2]);assert(i and i%1==0 and s.lastList and s.lastList[i],'use a number from shiphide list')
   local r=s.lastList[i];job=action=='hide' and s.hide(r.key,r) or s.show(r.key)
  elseif action=='undo' then job=s.undo()
  elseif action=='save' then s.save();report('component intent saved for this exact layout')
  elseif action=='load' then
   if pendingLoad then pendingLoad.error=nil end
   local ctx=s.context;assert(P.current(ctx,'edit')==true)
   local text,dirty=P.read_file(ctx,function()return api.is_live() and P.current(ctx,'edit')==true end)
   local payload=pendingLoad
   assert(type(text)=='string' and P.current(ctx,'edit')==true,'component intent read unavailable');job=s.change(C.decode(T,s.context.world,s.context.layout,text),{history=false,dirty=dirty==true});afterJob=function()if pendingLoad==payload then pendingLoad=nil;if P.file_applied then P.file_applied()end end;report('companion loaded')end
  else error('unknown action; use shiphide help') end
 end
 api.command('shiphide',function(_,args)
  -- Do not perform Native work on the command/input callback.
  if closing or #queue>=16 then report('busy/closing');return true end
  local ok,words=pcall(function()
   assert(type(args)=='table','command requires runtime scalar word array')
   local out={};assert(#args<=3,'too many command arguments')
   for _,v in ipairs(args) do assert(type(v)=='string' and #v<=128,'invalid command word');out[#out+1]=v end
   return out
  end)
  if ok then
   queue[#queue+1]=words
   report('queued '..table.concat(words,' ')..(job and '; waiting for component edit' or pendingLoad and '; waiting for companion apply' or '; next game tick'))
  else report(words) end;return true
 end)
 -- Production port current() also checks game-thread ownership before every call.
 api.loop(50,function()
  if job then
   local ok,done=pcall(job.step)
   if not ok then report('job exception: '..tostring(done));return end -- preserve journal; do not abandon a partial edit
   if done then
    local failure=job.error;local completed=job.ok;local finish=afterJob;afterJob=nil
    report(job.ok and 'component edit complete; shiphide save commits intent' or 'edit refused: '..tostring(job.error))
    if #job.rollback_errors>0 then report('rollback pending; use shiphide cleanup') end
    job=nil
    if not completed and pendingLoad then pendingLoad.error='ship companion apply failed: '..tostring(failure or 'component edit refused')end
    if completed and finish then local ok,why=pcall(finish);if not ok then report(why)end end
   end
   return
  end
  if not closing then subscribeLoad() end
  if pendingLoad and not pendingLoad.error then
   local ok,why=pcall(resumeLoad);if not ok then pendingLoad.error=tostring(why);report('companion unapplied: '..tostring(why)..'; use shiphide load')end;return
  end
  local words=table.remove(queue,1)
  if words then local ok,why=pcall(run,words);if not ok then report(why) end end
 end,{ungated=true})
 api.own(function()
  closing=true;queue={};pendingLoad=nil;if loadHook then loadHook();loadHook=nil end
  if not S then return true end
  afterJob=nil
  if job then local done,why=job.cancel();job=nil;if not done then return false,'ship edit rollback: '..tostring(why) end end
  local done,why=S.cleanup();if not done then return false,why end
  if next(S.applied) then
   local restore=S.restore_all();while not restore.step() do end
   if not restore.ok then return false,'ship original restoration: '..tostring(restore.error)..' '..table.concat(restore.rollback_errors,' | ') end
  end
  if P.release then P.release(S.context) end
  S.abandon();S=nil;return true
 end,function()
  -- Runtime terminal/world abandonment must revoke the native context FIRST.
  queue={};job=nil;pendingLoad=nil;afterJob=nil;loadHook=nil;if S then S.abandon();S=nil end
  if localProvider then localProvider.abandon();localProvider=nil end
 end)
 return {contract='ShipParts.Tools/v1',status=function()return {native_bound=Core.capabilities.get('ship_components_native')~=nil,
  active=S~=nil,dirty=S and S.dirty==true or false,pending=S and #S.pending or 0} end}
end
