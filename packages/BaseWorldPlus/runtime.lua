-- Small standalone bridge: the registry tracks scenery, not UI construction.
local M={}
function M.new(api)
 local Core=api.shared('Core')
 local L=Core.lifetime.new(api,{tick_owners=false})
 local E=Core.events.new(L)
 local X={api=api,C={CreativeMaps=true},H={},Lifetime=L,revision=0,reports={},hooks={},replies={}}
 X.work=Core.work_budget.new(api,{ms=6,reserve=3,items=512,profile=function(label,ms)
  local limit=label=='work:slice' and 6 or 3
  if ms>limit then api.log(string.format('work overrun %s %.2f ms (limit %.0f)',label,ms,limit)) end
 end})
 X.clock=Core.event_clock.new()
 X.identity=Core.match_identity.new(L)
 X.CREATIVE='/Game/Blueprints/Gamemodes/CreativeMode/'; X.OM='/Game/Blueprints/Gamemodes/ObjectiveMode/'
 X.read=Core.runtime.read
 X.call=Core.runtime.call
 X.get=Core.runtime.unwrap
 function X.text(o) if type(o)=='string' then return o end; return X.call(o,'ToString') or '' end
 function X.values(a)
  local rows={}; if not a then return rows end
  if type(a)=='table' and X.read(a,'ForEach')==nil then for _,v in ipairs(a) do rows[#rows+1]=X.get(v) end
  else pcall(function() a:ForEach(function(_,v) rows[#rows+1]=X.get(v) end) end) end
  return rows
 end
 function X.log(stage,s) api.log(stage..': '..tostring(s)) end
 function X.once(k,stage,s) if X.reports[k]~=s then X.reports[k]=s; X.log(stage,s) end end
 local replyRecord,replyOutcome,replySerial,replyGeneration=nil,nil,0,0
 local replyJobs={}
 local resetReplies
 local function replyOwnerLive()
  local live=api.is_live()
  -- Native terminal detaches package callbacks rather than invoking cleanup.
  -- An explicit old-owner access can still retire these Lua-only captures.
  if not live and next(replyJobs) then resetReplies() end
  return live
 end
 local function currentReplyOwner(epoch,generation)
  return replyOwnerLive() and epoch==L.epoch and generation==replyGeneration and not L.transition
 end
 local function outcome(r,state,reason)
  if not replyOutcome or r.serial>=replyOutcome.serial then
   replyOutcome={generation=r.generation,epoch=r.epoch,serial=r.serial,count=r.count,state=state,reason=reason}
  end
 end
 function X.replyOutcome()
  replyOwnerLive()
  if not replyOutcome then return end
  local copy={};for k,v in pairs(replyOutcome) do copy[k]=v end;return copy
 end
 local function finish(r,state,reason)
  if r.closed then return false end
  r.count=r.batch and #r.batch or r.count
  r.closed=true
  if replyJobs[r.key]==r then replyJobs[r.key]=nil end
  if replyRecord==r then replyRecord=nil end
  if X.replies==r.batch then X.replies={} end
  outcome(r,state,reason) -- commit before any ordinary diagnostic/reentry
  r.batch=nil;r.job=nil;r.step=nil
  return true
 end
 local function diagnostic(r,text)
  if currentReplyOwner(r.epoch,r.generation) then pcall(X.rawLog,'Reply',text) end
 end
 local cancelWork=X.work.cancel
 function X.work.cancel(key,...)
  local r=replyJobs[key]
  local job=X.work.keys[key]
  local owned=r and not r.closed and job and job.step==r.step
  local result=table.pack(pcall(cancelWork,key,...))
  if owned and finish(r,'canceled','work_cancel') then diagnostic(r,'reply dispatch canceled') end
  if not result[1] then error(result[2],0) end
  return table.unpack(result,2,result.n)
 end
 resetReplies=function()
  replyGeneration=replyGeneration+1
  for _,r in pairs(replyJobs) do finish(r,'retired','owner_retired') end
  replyJobs={};replyRecord=nil;X.replies={}
 end
 local function dispatchReplies()
  local batch,epoch,generation=X.replies,L.epoch,replyGeneration
  if #batch==0 or not currentReplyOwner(epoch,generation) then return end
  if replyRecord and replyRecord.batch==batch and not replyRecord.closed then
   replyRecord.count=#batch;outcome(replyRecord,'accepted','queued');return
  end
  replySerial=replySerial+1
  local key='reply-dialog:'..replySerial
  local r={key=key,batch=batch,epoch=epoch,generation=generation,serial=replySerial,count=#batch}
  replyJobs[key]=r;replyRecord=r;outcome(r,'accepted','queued')
  local step
  local ok,accepted=pcall(function()
   step=X.work.native(function()
   if r.closed or r.entered then return end
   if not currentReplyOwner(epoch,generation) then finish(r,'retired','owner_retired');return end
   local job=X.work.keys[key]
   if not job or job.step~=r.step or X.replies~=r.batch or not currentReplyOwner(epoch,generation) then
    if finish(r,'canceled','lease_lost') then diagnostic(r,'reply dispatch canceled') end
    return
   end
   r.job=job
   local function lease()
    return not r.closed and replyJobs[key]==r and X.work.keys[key]==job and currentReplyOwner(epoch,generation)
   end
   local ok,err=pcall(X.dialog,lease)
   if not ok then
    if finish(r,'failed','action_error') then diagnostic(r,'reply dispatch failed') end
    error(err,0)
   end
   finish(r,'completed','dialog_returned')
   end)
   r.step=step
   return X.work.submit(key,'command replies',step)
  end)
  if not ok then
   local owned=currentReplyOwner(epoch,generation) and X.work.keys[key]
   local finished=finish(r,'failed','submit_error')
   if owned and owned.step==step then pcall(cancelWork,key) end
   if finished then diagnostic(r,'reply dispatch failed') end
   error(accepted,0)
  end
  if not accepted and finish(r,'failed','submit_rejected') then diagnostic(r,'reply dispatch rejected') end
 end
 function X.queueReply(stage,s)
  if not replyOwnerLive() then return end
  local epoch,generation=L.epoch,replyGeneration
  if not currentReplyOwner(epoch,generation) then return end
  X.rawLog(stage,s)
  if not currentReplyOwner(epoch,generation) then return end
  local text=tostring(s)
  if not currentReplyOwner(epoch,generation) then return end
  if #X.replies<512 then X.replies[#X.replies+1]=text end
  dispatchReplies()
 end
 api.own(resetReplies,resetReplies)
 X.rawLog=X.log; X.reply=X.queueReply; X.notice=X.rawLog
 local capture=false
 function X.log(stage,s) if capture then X.queueReply(stage,s) else X.rawLog(stage,s) end end
 function X.command(fn,...)
  local epoch,generation=L.epoch,replyGeneration
  local prior=capture; capture=true; local r=table.pack(pcall(fn,...)); capture=prior
  if not r[1] and currentReplyOwner(epoch,generation) then
   local replied=pcall(function()
    X.rawLog('Command','Refused: '..tostring(r[2]))
    local text=Core.runtime.player_error(r[2])
    if currentReplyOwner(epoch,generation) then X.reply('Command',text) end
   end)
   if not replied and currentReplyOwner(epoch,generation) then
    pcall(X.rawLog,'Reply','command error retained; reply dispatch unavailable')
   end
  end
  return table.unpack(r,1,r.n)
 end
 function X.object(path) local o=StaticFindObject(path); assert(L.rawValid(o),'native object not loaded: '..path); return o end
 function X.gameplay() return X.object('/Script/Engine.Default__GameplayStatics') end
 function X.gi(o) return X.gameplay():GetGameInstance(o) end
 X.H.valid=L.valid
 function X.H.authority(o) return L.valid(o) and X.call(o,'HasAuthority')==true end
 function X.live(o) return not L.transition and L.valid(o) and not o:GetFullName():find('Default__',1,true) end
 function X.same(a,b) return L.same(a,b) end
 function X.editing(gm)
  if not X.live(gm) or not X.H.authority(gm) then return false end
  local gs=X.gameplay():GetGameState(gm)
  return X.live(gs) and X.read(gs,'IsPlayTestMode')==false
 end
 local fields={file='FileName_6_F3CC8069497D007AD2E96A9AE00D2700'}
 function X.field(o,k) return X.read(o,k) or X.read(o,fields[k] or '') end
 X.Preflight={path=function(gi,layout)
  local path=X.text(X.field(layout,'file')):gsub('\\','/')
  if path=='' or path=='None' then return end
  if path:sub(1,1)=='/' or path:match('^%a:/') then return path end
  local current=X.text(X.read(X.read(gi,'MapManager'),'CurrentWorkshopFile')):gsub('\\','/')
  if current:match('([^/]+)$')==path then return current end
  -- Convert only explicit relative paths; bare names have no unambiguous directory.
  if path:find('/',1,true) then return X.call(X.object('/Script/Engine.Default__BlueprintPathsLibrary'),'ConvertRelativePathToFull',path) end
 end}
 function X.mapRequiresMod(path) if type(path)~='string' then return false end; local f=io.open(path..'.faphidden','rb'); if f then f:close(); return true end; return false end
 function X.message(_,s) X.reply('Network',s) end
 X.worldObjects=api.world_objects
 function X.findAll(c) return X.Registry.list(c) end
 function X.cachedPoll(consumer,pending) E.poll(consumer,X,X.Registry,pending) end
 local deferred={}
 function X.defer(fn)
  local cancel
  cancel=api.delay(1,function() deferred[cancel]=nil;fn() end)
  deferred[cancel]=true;return cancel
 end
 L.onReset(function() for cancel in pairs(deferred) do cancel() end;deferred={} end)
 function X.commandHandler(name,fn)
  return api.command(name,function(...) local result=fn(...); if X.wake then X.wake() end; return result end)
 end
 function X.hook(stage,folder,asset,method,fn)
  local path=folder..asset..'.'..asset..'_C:'..method
  X.hooks[path]={fn=fn,stage=stage}
  api.hook(path,function(...)
   if L.transition then return end
   X.revision=X.revision+1
   local result=fn(...)
   if X.wake then X.wake() end
   return result
  end)
  return path
 end
 local coreGM='/Game/Blueprints/Core/B_GameMode.B_GameMode_C'
 local paths={B_GameMode_C=coreGM,B_GameInstance_C='/Game/Blueprints/Core/B_GameInstance.B_GameInstance_C',
  B_CreativeGameMode_C=X.CREATIVE..'B_CreativeGameMode.B_CreativeGameMode_C',
  B_CreativePlayerController_C=X.CREATIVE..'B_CreativePlayerController.B_CreativePlayerController_C',
  B_ObjectiveGameMode_C=X.OM..'B_ObjectiveGameMode.B_ObjectiveGameMode_C',
  B_ObjectivePlayerController_C=X.OM..'B_ObjectivePlayerController.B_ObjectivePlayerController_C',
  B_PlayerController_C='/Game/Blueprints/Player/B_PlayerController.B_PlayerController_C'}
 local scenery=api.module('scenery')
 for _,c in ipairs(scenery.classes) do
  paths[c]=scenery.classPaths and scenery.classPaths[c] or (c=='NiagaraActor' and '/Script/Niagara.' or '/Script/Engine.')..c
 end
 X.Registry=Core.registry.new(api,L,paths,{persistent={B_GameInstance_C=true},
  ready_events=false,validate_list=false,inherited={B_GameMode_C=true}})
 X.buckets=X.Registry.buckets;X.metadata=X.Registry.metadata
 X.track=X.Registry.track
 function X.scan()
  if X.scanning or L.transition then return end
  X.scanning=true
  local steps={}
  for class in pairs(paths) do
   local snapshot
   steps[#steps+1]=X.work.native(function() snapshot=api.find_all(class) end)
   steps[#steps+1]=X.work.defer(function() return X.work.each(snapshot,function(o) X.Registry.track(o,class) end) end)
  end
  steps[#steps+1]=function() X.scanning=false;if X.wake then X.wake() end;return true end
  X.work.submit('destination-inventory','destination inventory',X.work.sequence(steps))
 end
 function X.dialog(lease)
  if not replyOwnerLive() then return end
  local epoch,generation=L.epoch,replyGeneration
  local r=replyRecord and replyRecord.batch==X.replies and replyRecord or nil
  local function current()
   return currentReplyOwner(epoch,generation) and (not r or not r.closed)
    and (not lease or lease())
  end
  if #X.replies==0 or not current() then return end
  local rows=X.replies; X.replies={}
  if r then r.entered=true;if replyRecord==r then replyRecord=nil end end
  local ok,reason=pcall(function()
   local instances=X.findAll('B_GameInstance_C')
   if not current() then return 'lease_lost' end
   for _,gi in ipairs(instances) do
    if not current() then return 'lease_lost' end
    local valid=L.valid(gi)
    if not current() then return 'lease_lost' end
    if valid then
     local manager=X.read(gi,'MenuUIManager')
     if not current() then return 'lease_lost' end
     local mounted=L.valid(manager)
     if not current() then return 'lease_lost' end
     if mounted then
      manager:ShowMessageDialog('Editor tweaks',table.concat(rows,'\n'))
      return 'dialog'
     end
    end
   end
   return 'unavailable'
  end)
  if not ok then
   if r and finish(r,'failed','action_error') then diagnostic(r,'reply dispatch failed') end
   error(reason,0)
  end
  if r then finish(r,reason=='lease_lost' and 'canceled' or 'completed',reason) end
 end
 L.onReset(function()
  resetReplies();X.revision=X.revision+1;X.reports={};X.scanning=false;X.work.reset()
 end)
 L.install()
 return X
end
return M
