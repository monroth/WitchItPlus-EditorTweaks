-- Direct console editing with an independent native layout-file observer.
local dir=assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))
local Editor=dofile(dir..'teleporter_editor.lua')
local Native=dofile(dir..'teleporter_native.lua')
local M={}
function M.install(X,options)
 options=options or {};local editorOptions={};for k,v in pairs(options.editor or {})do editorOptions[k]=v end
 editorOptions.reader=editorOptions.reader or options.reader
 if not editorOptions.decor_claims then
  local broker=assert(X.api.shared('Core').actor_edit_claims,'shared actor reservations unavailable')
  editorOptions.decor_claims=broker.for_owner(X.api,X.api.map_document,X.Lifetime,'teleporter_decor')
 end
 local T=Editor.new(X,editorOptions)
 local B={editor=T};local closing=false;local files;local traceScope
 local function refresh()
  assert(not closing and X.api.is_live(),'teleporter package retired')
  local v=(options.document or Native.document)(X)
  local accepted,why=T.bind_current(v);assert(accepted,why)
  return nil,v
 end
 function B.reload_bound()
  return assert(files,'layout file observer unavailable').reload()
 end
 local function words(args)
  assert(type(args)=='table' and #args<=24,'too many teleporter arguments')
  local out={}
  for i,v in ipairs(args) do assert(type(v)=='string' and #v<=4096 and not v:find('[%c]'),'literal teleporter arguments required');out[i]=v end
  return out
 end
 local function number(args,i)local n=tonumber(args[i]);assert(n and n==n and math.abs(n)<math.huge,'finite numeric argument required');return n end
 local function point(args,i)return {X=number(args,i),Y=number(args,i+1),Z=number(args,i+2),Yaw=number(args,i+3)}end
 local function arity(args,n)assert(#args==n,'wrong teleporter argument count')end
 local function boolean(v)assert(v=='on' or v=='off','use on/off');return v=='on'end
 function B.command(args)
  args=words(args);assert(not closing and X.api.is_live(),'teleporter package retired')
  local command=args[1] or 'list'
  -- These report local editor state; no world/document/native editing admission.
  if command=='status' then arity(args,1);local status=T.status();X.reply('Teleporters',(status.dirty and 'Unsaved changes.'or 'Changes saved.')..' Undo steps: '..(status.undo or 0)..((files and files.error()or status.error)and ' Saved teleporters unavailable; use bteleport reload.'or ''));return true
  elseif command=='trace' then
   arity(args,1);traceScope=traceScope or X.api.Native.scope(X.api.id);local ok,why=traceScope.teleport_trace();assert(ok,why or 'native teleport trace unavailable');X.reply('Teleporters','Tracing the next teleport.');return true
  elseif command=='help' then
   arity(args,1);X.reply('Teleporters','bteleport list | add NAME X Y Z YAW EXIT_X EXIT_Y EXIT_Z EXIT_YAW | remove/restore ID | target/move ID X Y Z YAW | link/pair ID ID | extent ID X Y Z | options ID on/off on/off MULTIPLIER | decor ID SCENERY_NAME | undecor ID | undo | reload | status | trace.');return true
  end
  assert(not files or not files.waiting()or command=='reload','teleporter companion loading; wait for the loaded log or use bteleport reload')
  refresh()
  local yes,why=true,nil
  if command=='list' then
   arity(args,#args==0 and 0 or 1);local rows=T.list();local names={};for id in pairs(rows)do names[#names+1]=id end;table.sort(names)
   for i,id in ipairs(names)do local r=rows[id];X.reply('Teleporters',i..' '..id..' '..(r.removed and 'disabled' or 'enabled')..' -> '..(r.link or string.format('%.1f %.1f %.1f / %.1f',r.exit.X,r.exit.Y,r.exit.Z,r.exit.Yaw)))end
   return true
  elseif command=='add' then arity(args,10);yes,why=T.add(args[2],point(args,3),point(args,7))
  elseif command=='remove' then arity(args,2);yes,why=T.remove(args[2])
  elseif command=='restore' then arity(args,2);yes,why=T.restore(args[2])
  elseif command=='target' then arity(args,6);yes,why=T.target(args[2],point(args,3))
  elseif command=='move' then arity(args,6);yes,why=T.move(args[2],point(args,3))
  elseif command=='link' then arity(args,3);yes,why=T.link(args[2],args[3])
  elseif command=='pair' then arity(args,3);yes,why=T.pair(args[2],args[3])
  elseif command=='extent' then arity(args,5);yes,why=T.resize(args[2],{X=number(args,3),Y=number(args,4),Z=number(args,5)})
  elseif command=='options' then arity(args,5);yes,why=T.options(args[2],boolean(args[3]),boolean(args[4]),number(args,5))
  elseif command=='decor' then arity(args,3);yes,why=T.decorate(args[2],args[3])
  elseif command=='undecor' then arity(args,2);yes,why=T.undecorate(args[2])
  elseif command=='undo' then arity(args,1);yes,why=T.undo()
  elseif command=='reload' then arity(args,1);yes,why=B.reload_bound()
  else error('unknown teleporter command; use bteleport help')end
  assert(yes,why);X.reply('Teleporters','Changed. Save the map to keep it.');return true
 end
 -- Native console dispatch already runs on the game thread. Execute against
 -- the current layout now; no queued work, captured document or admission token.
 B.enqueue=B.command
 X.commandHandler('bteleport',function(_,args)B.command(X.values(args));return true end)
 function B.cleanup()
  closing=true
  if files then files.close()end
  local yes,why=T.cleanup();if not yes then return false,'Teleporters: '..tostring(why)end
  return T.retire()
 end
 X.api.own(B.cleanup,function()closing=true;if files then files.close()end;T.retire()end)
 if not options.no_files then
  files=dofile(dir..'teleporter_files.lua').install(X,T,options)
 end
 return B
end
return M
