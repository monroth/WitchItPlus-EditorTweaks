-- True persistent-world Creative authoring. No streamed duplicate or .pl conversion.
local M={}
function M.init(X,dir)
 local catalog=dofile(dir..'world_catalog.lua')
 local GM=X.CREATIVE..'B_CreativeGameMode.B_CreativeGameMode_C'
 local api={}
 local function pick(name)
  for key,r in pairs(catalog) do
   if key:lower()==name:lower() or (r.path:match('/([^/]+)$') or ''):lower()==name:lower() then return r end
  end
 end
 function api.command(args)
  local action=args[1] or 'help'
  if action=='list' then
   local names={}; for name in pairs(catalog) do names[#names+1]=name end; table.sort(names)
   for _,name in ipairs(names) do local r=catalog[name]
    if not args[2] or name:lower():find(args[2]:lower(),1,true) then X.reply('World',name..' ['..r.kind..']'..(r.unavailable and ' unavailable' or '')) end
   end
  elseif action=='open' then
   assert(#args==2,'bworld open <name>; start a NEW empty solo Creative layout first')
   local r=pick(args[2]); assert(r and not r.unavailable,'world unknown or cooked package absent; bworld list')
   local gm
   for _,o in ipairs(X.findAll('B_CreativeGameMode_C')) do if X.editing(o) then gm=o; break end end
   assert(gm,'open Creative as solo host, outside Playtest')
   local gp=X.gameplay(); local gs=gp:GetGameState(gm); local gi=X.gi(gm); local pc=gp:GetPlayerController(gm,0)
   assert(X.live(pc) and X.call(pc,'IsLocalPlayerController')==true,'local Creative controller required')
   assert(tonumber(X.read(gs,'CurrentPropAmount'))==0 and tonumber(X.read(gs,'CurrentPlaceableStaticAmount'))==0,
    'occupied Creative layout: save your work and create a NEW empty layout')
   assert(X.text(X.read(gm,'LoadedLayoutName'))=='' and X.text(X.read(gm,'LoadedLayoutFullPath'))=='',
    'create a NEW empty layout before world travel')
   local peers=0; local seen={}
   for _,cls in ipairs({'B_PlayerController_C','B_CreativePlayerController_C','B_ObjectivePlayerController_C'}) do
    for _,o in ipairs(X.findAll(cls)) do if X.live(o) and X.Lifetime.sameWorld(o,gm) then
     local id=X.Lifetime.key(o); if not seen[id] then seen[id]=true; peers=peers+1 end
    end end
   end
   assert(peers==1,'world opening is solo only; disconnect guests first')
   -- Counts may lag one event: query only serializable actors in this world.
   local occupied=false
   for _,class in ipairs({'/Game/Blueprints/Props/Bases/B_StaticMeshProp.B_StaticMeshProp_C',
    '/Game/Blueprints/StaticProps/Placeable/BP_PlaceableStaticProp.BP_PlaceableStaticProp_C',
    '/Game/Blueprints/StaticProps/Placeable/Utility/BP_BaseUtilityPlaceable.BP_BaseUtilityPlaceable_C'}) do
    if #X.worldObjects(class,gm)>0 then occupied=true end
   end
   assert(not occupied,'native saved actors remain; create a NEW empty layout')
   local options=X.read(gi,'CreativeMatchOptions'); assert(X.H.valid(options),'CreativeMatchOptions unavailable')
   local map=X.read(options,'MapData'); local layout=X.read(options,'LayoutData')
   assert(map and layout,'native options structs unavailable')
   options:SetGameMode(X.object(GM))
   for k,v in pairs({IsCreativeMode=true,IsPublicCreative=false,IsPublic=false,MaxPlayers=1,EnableIdleKick=false,
    IsTournamentMode=false,IsRecordingMode=false,UseCustomLayouts=false,CustomMapSelected=false,
    MapChangedAfterLoadingCustomLayout=false,SelectedLayout=-1}) do options[k]=v end
   map.FileName_10_98BC71FF40A2DA9A28FA21B92157D6D9=FName(r.path)
   if r.mapType then map.MapType_51_1AFFC617422AF107FB7517B52DD9E5D2=r.mapType end
   for _,field in ipairs({'FileName_6_F3CC8069497D007AD2E96A9AE00D2700','LayoutName_8_C5C516E347406BABDAF0F59A6150BC5A',
    'ScreenshotFile_15_EAD1980E4D724129C57CEE95149A80DD'}) do layout[field]='' end
   layout.MapName_10_67B8E5E54A16D786C60266AF5B396E36=r.path:match('/([^/]+)$')
   layout.LayoutType_3_723A46B84CDA3855FEC9D49D6379A874=1
   gi.UsedMatchOptions=options
   X.rawLog('World','opening REAL persistent world '..r.path..'; native candidate')
   gp:OpenLevel(gi,FName(r.path),true,'?game='..GM)
  else X.reply('World','bworld list [filter] | bworld open <map name>') end
 end
 return api
end
return M
