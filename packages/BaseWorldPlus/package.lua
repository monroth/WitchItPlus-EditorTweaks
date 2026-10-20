return function(api)
 local X=api.module('runtime').new(api)
 local L=X.Lifetime
 local scope=api.shared('UIKit').new(api)
 local Sync=api.module('maps_modsync').init(X)
 local Hide=api.module('maps_suppression').init(X)
 local Worlds=api.module('worlds').init(X,api.path..'/')
 local Teleporters=api.module('teleporter_install').install(X)
 local Core=api.shared('Core')
 local files=api.module('ship_files').new({document=api.map_document,files=Core.layout_files,io=Core.companion_io,log=api.log,current=api.is_live})
 api.own(files.retire,files.retire)
 Core.capabilities.claim(api,'native_scalar_storage',files)
 assert(api.Native.scope(api.id).on_tick(files.poll),'ship file observer tick unavailable')
 local Ship=api.module('ship_tools')(api)
 local worldQueue={}
 local ready=false
 local dirty=false
 local function pass()
  return X.work.sequence({
   function() X.clock.tick();return true end,
   function() Sync.poll();return true end,
   function() Hide.poll();return true end,
   function() Hide.tick(X.clock.now());return true end,
   function()
    local args=table.remove(worldQueue,1)
    if args then X.work.submit('world-command','world command',X.work.native(function() X.command(Worlds.command,args) end)) end
    return true
   end,
   function() X.dialog();return true end,
  })
 end
 local function maintenance()
  local step=pass()
  return function()
   if step() then
    if dirty then dirty=false;step=pass();return false end
    return true
   end
   return false
  end
 end
 function X.wake()
  if ready and not L.transition and not X.scanning then
   dirty=true
   if X.work.submit('maintenance','hide and network settlement',maintenance()) then dirty=false end
  end
 end
 X.commandHandler('bworld',function(_,args)
  if #worldQueue<16 then worldQueue[#worldQueue+1]=X.values(args) end
  return true
 end)
 X.hook('Chat','/Game/Blueprints/UserInterface/','B_IngameUIManager','ParseChatCommand',function(_,text)
  local words={};for word in X.text(X.get(text)):gmatch('%S+') do words[#words+1]=word end
  local root=(table.remove(words,1) or ''):lower()
  if root=='/hide' or root=='/bwhide' or root=='/faphide' then Hide.enqueue(words,true)
  elseif root=='/bworld' and #worldQueue<16 then worldQueue[#worldQueue+1]=words end
  -- Native ParseChatCommand already marks slash roots; no undeclared OUT write.
 end)
 local function interested(class)
  return X.Registry.classes[class]==true
 end
 api.on('begin_play_post',function(p)
  local o=X.get(p);X.Registry.ready(o)
  local class=X.text(X.call(X.call(o,'GetClass'),'GetFName'))
  if class:find('PlayerController',1,true) then Sync.begin(o) end
  X.wake()
 end,{class_filter=interested})
 X.Registry.onChange[#X.Registry.onChange+1]=function() X.wake() end
 api.on('world_ready',function() ready=true;X.scan();X.wake() end,{ungated=true})
 api.on('load_map_post',function() ready=true;X.scan();X.wake() end,{ungated=true})
 L.onReset(function() ready=false;dirty=false;worldQueue={};Hide.abandon();Sync.reset() end)
 -- The timer only services pending handshakes/aim; idle performs no reflection.
 api.loop(250,function()
  if Hide.active() or Sync.pending() or #worldQueue>0 or #X.replies>0 then X.wake() end
 end)
 local cleanupStarted,rollbackDone=false,false
 local releaseCapability
 local function owned(fn)
  return function(...)
   if cleanupStarted or api.is_active and not api.is_active() then return end
   return fn(...)
  end
 end
 releaseCapability=api.shared('Core').capabilities.claim(api,'layout_hiding',
  {enqueue=owned(Hide.enqueue),key=owned(Hide.key),owner=api.id,
   actor_claimed=Hide.actorClaimed,document=api.map_document,current=function() return not cleanupStarted and api.is_live() end,
  },
  {release_ready=function() return rollbackDone end})
 api.own(function()
  cleanupStarted=true
  X.work.reset();Sync.reset()
  local done,why=Hide.cleanup();rollbackDone=done~=false
  if not rollbackDone then return false,'base-world hide rollback: '..tostring(why) end
  return not releaseCapability or releaseCapability()
 end,function()
  -- Proven epoch abandonment drops Lua ownership without replaying Native rollback.
  cleanupStarted=true;rollbackDone=true;ready=false;dirty=false;worldQueue={}
  Hide.abandon();Sync.reset()
 end)
 ready=true;X.scan();X.wake()
 api.publish({hide=Hide,worlds=Worlds,ship=Ship})
 api.log('ready: Editor tweaks; shiphide; bwhide /hide; bworld list/open; bwmodstatus; commands only')
end
