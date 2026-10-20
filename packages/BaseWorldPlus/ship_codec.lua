-- Stable, bounded intent only. No UObject addresses or session handles on disk.
local M={limit=256,bytes=65536}
local function token(v,n) return type(v)=='string' and #v>0 and #v<=n and not v:find('[%c|]') end
function M.validate(T,world,layout,actor,component)
 assert(world==T.world,'ship world differs from cooked policy')
 assert(token(layout,256),'invalid layout identity')
 assert(token(actor,1024) and actor:sub(1,#world+17)==world..':PersistentLevel.','invalid authored actor path')
 local name=actor:sub(#world+18)
 assert(name:match('^[%w_]+$') and not name:find('Default__',1,true),'invalid authored actor name')
 assert(type(component)=='string' and T.parts[component]~=nil,'component absent from cooked ship')
 return actor..'|'..component
end
function M.decode(T,world,layout,text)
 assert(type(text)=='string' and #text<=M.bytes and text:sub(-1)=='\n','invalid ship intent file')
 local lines={};for line in text:gmatch('([^\n]*)\n') do lines[#lines+1]=line end
 assert(lines[1]=='SHIP_PARTS_V1' and lines[2]==world and lines[3]==layout and lines[4]==T.fingerprint,'ship intent identity/version/topology mismatch')
 assert(#lines-4<=M.limit,'too many hidden ship components')
 local set={}
 for i=5,#lines do
  local actor,component=lines[i]:match('^([^|]+)|([^|]+)$')
  local key=M.validate(T,world,layout,actor,component)
  assert(not set[key],'duplicate component intent')
  set[key]={actor=actor,component=component}
 end
 return set
end
function M.encode(T,world,layout,set)
 assert(world==T.world and token(layout,256),'invalid ship document')
 local keys={}
 for key,d in pairs(set) do
  assert(key==M.validate(T,world,layout,d.actor,d.component),'intent key differs from descriptor')
  keys[#keys+1]=key
 end
 assert(#keys<=M.limit,'too many hidden ship components');table.sort(keys)
 local lines={'SHIP_PARTS_V1',world,layout,T.fingerprint};for _,key in ipairs(keys) do lines[#lines+1]=key end
 local text=table.concat(lines,'\n')..'\n';assert(#text<=M.bytes,'ship intent too large');return text
end
return M
