-- Hex Repeat. Штатные инструменты редактируют исходный слой.
-- Шесть копий хранятся в отдельном заблокированном служебном слое.
local Hex = { version="1.2" }

local function alive(sprite)
  if not sprite then return false end
  local ok, valid = pcall(function() return sprite.isValid end)
  return ok and valid == true
end

-- Сохраняем точные пиксели выделения, не восстанавливая геометрию по размерам.
function Hex.mask(selection, sprite)
  assert(not selection.isEmpty, "Выдели точную форму одного гекса.")
  local bounds = selection.bounds
  assert(bounds.width*bounds.height<=1048576,
    "Маска слишком велика для этого режима. Выдели область одного тайла.")
  assert(bounds.x >= 0 and bounds.y >= 0
    and bounds.x + bounds.width <= sprite.width
    and bounds.y + bounds.height <= sprite.height,
    "Выделение должно находиться внутри холста.")
  local copy, rows = Selection(), {}
  copy:add(selection)
  for y = 0, bounds.height - 1 do
    rows[y + 1] = {}
    for x = 0, bounds.width - 1 do
      if copy:contains(bounds.x + x, bounds.y + y) then
        rows[y + 1][#rows[y + 1] + 1] = x
      end
    end
  end
  return { selection=copy, bounds=Rectangle(bounds), rows=rows }
end

-- Выбираем палитру текущего кадра, не меняя палитру документа.
local function framePalette(sprite, frameNumber)
  local selected, selectedFrame = sprite.palettes[1], -1
  for i = 1, #sprite.palettes do
    local palette = sprite.palettes[i]
    local number = palette.frame.frameNumber
    if number <= frameNumber and number >= selectedFrame then
      selected, selectedFrame = palette, number
    end
  end
  return selected
end

-- Преобразуем только изображение просмотра в RGBA. Исходные индексы сохраняются.
function Hex.capture(sprite, layer, frameNumber, mask)
  local bounds = mask.bounds
  local result = Image(bounds.width, bounds.height, ColorMode.RGB)
  local cel = layer:cel(frameNumber)
  if not cel then return result end
  local source, position = cel.image, cel.position
  local colors
  if source.colorMode == ColorMode.INDEXED then
    colors = {}
    local palette = framePalette(sprite, frameNumber)
    for index = 0, #palette - 1 do
      local c = palette:getColor(index)
      local alpha = c.alpha
      if index == sprite.transparentColor and not layer.isBackground then alpha = 0 end
      if layer.isBackground then alpha = 255 end
      colors[index] = app.pixelColor.rgba(c.red, c.green, c.blue, alpha)
    end
  end
  for y, row in ipairs(mask.rows) do
    local iy = bounds.y + y - 1 - position.y
    if iy >= 0 and iy < source.height then
      for _, x in ipairs(row) do
        local ix = bounds.x + x - position.x
        if ix >= 0 and ix < source.width then
          local pixel = source:getPixel(ix, iy)
          if colors then
            assert(colors[pixel] ~= nil, "В рисунке есть индекс вне палитры.")
            pixel = colors[pixel]
          end
          result:drawPixel(x, y - 1, pixel)
        end
      end
    end
  end
  return result
end

-- Проверяем числа до расчёта координат, ошибку можно исправить без закрытия панели.
function Hex.geometry(stepX, rowX, rowY)
  local numbers = { stepX, rowX, rowY }
  for i = 1, 3 do
    local number = numbers[i]
    assert(type(number) == "number" and number == number
      and number == math.floor(number) and math.abs(number) <= 8192,
      "Смещения должны быть целыми числами от −8192 до 8192.")
  end
  assert(stepX > 0 and rowY > 0, "Шаг X и шаг ряда Y должны быть больше нуля.")
  return { stepX=stepX, rowX=rowX, rowY=rowY }
end

-- Извлекаем индексы или RGBA без преобразования палитры исходного документа.
function Hex.captureNative(sprite, layer, frameNumber, mask)
  local spec = ImageSpec{width=mask.bounds.width, height=mask.bounds.height,
    colorMode=sprite.colorMode, transparentColor=sprite.transparentColor}
  local image = Image(spec)
  image:clear(sprite.colorMode == ColorMode.INDEXED and sprite.transparentColor or 0)
  local cel = layer:cel(frameNumber)
  if not cel then return image end
  for y, row in ipairs(mask.rows) do
    local iy = mask.bounds.y + y - 1 - cel.position.y
    if iy >= 0 and iy < cel.image.height then
      for _, x in ipairs(row) do
        local ix = mask.bounds.x + x - cel.position.x
        if ix >= 0 and ix < cel.image.width then
          image:drawPixel(x,y-1,cel.image:getPixel(ix,iy))
        end
      end
    end
  end
  return image
end

local marker = "HexRepeat/1\n"
local function metadata(layer)
  local data = layer.data
  if data:sub(1,#marker) ~= marker then return nil end
  local ok, value = pcall(json.decode,data:sub(#marker+1))
  if ok and (type(value)=="table" or type(value)=="userdata") then return value end
end

-- Ищем только собственный слой копий, пользовательские слои не переиспользуются.
local function findCopies(parent, source)
  for _, layer in ipairs(parent.layers) do
    if layer.isGroup then
      local copies,data=findCopies(layer,source)
      if copies then return copies,data end
    else
      local data=metadata(layer)
      if data and data.source==tostring(source.uuid) then return layer,data end
    end
  end
end

local function movedMask(mask, dx, dy)
  mask.selection.origin=Point(mask.bounds.x+dx,mask.bounds.y+dy)
  mask.bounds=Rectangle(mask.bounds.x+dx,mask.bounds.y+dy,mask.bounds.width,mask.bounds.height)
end

-- Границы всего первого круга, без фиксированного размера экрана.
function Hex.footprint(mask, geometry)
  local x=math.max(geometry.stepX,math.abs(geometry.rowX))
  return Rectangle(mask.bounds.x-x,mask.bounds.y-geometry.rowY,
    mask.bounds.width+2*x,mask.bounds.height+2*geometry.rowY)
end

local function transparentImage(sprite, width, height)
  local image=Image(ImageSpec{width=width,height=height,colorMode=sprite.colorMode,
    transparentColor=sprite.transparentColor})
  image:clear(sprite.colorMode==ColorMode.INDEXED and sprite.transparentColor or 0)
  return image
end

-- Порядок соседей совпадает со схемой панели, центр в этот список не входит.
local function offsets(g)
  return {{-g.rowX,-g.rowY},{g.rowX,-g.rowY},{-g.stepX,0},
    {g.stepX,0},{-g.rowX,g.rowY},{g.rowX,g.rowY}}
end

local function neighborMask(mask, p)
  local selection=Selection()
  selection:add(mask.selection)
  local result={selection=selection,bounds=Rectangle(mask.bounds),rows=mask.rows}
  movedMask(result,p[1],p[2])
  return result
end

local gridMarker="HexRepeatGrid/1\n"
local solidGridMarker="HexRepeatGridStyle/1\nsolid"

-- Служебная сетка находится отдельно от рисунка и не участвует в обычном экспорте.
local function findGrid(sprite,source)
  for _,layer in ipairs(sprite.layers) do
    if layer.isReference and layer.data==gridMarker..tostring(source.uuid) then return layer end
  end
end

-- Обводим точные края каждой маски, включая внутренние границы объединённого выделения.
function Hex.gridImage(mask,geometry,sprite,frameNumber,solid)
  local area=Hex.footprint(mask,geometry)
  local image=transparentImage(sprite,area.width,area.height)
  local dark,light=app.pixelColor.rgba(0,0,0,255),app.pixelColor.rgba(255,255,255,255)
  if sprite.colorMode==ColorMode.INDEXED then
    -- Выбираем контрастные существующие индексы, исключая прозрачный цвет.
    local palette=framePalette(sprite,frameNumber)
    local darkest,lightest=math.huge,-math.huge
    dark,light=nil,nil
    for index=0,#palette-1 do
      local color=palette:getColor(index)
      if index~=sprite.transparentColor and color.alpha>0 then
        -- Сравниваем яркость цветов без изменения исходной палитры.
        local luminance=299*color.red+587*color.green+114*color.blue
        if luminance<darkest then darkest,dark=luminance,index end
        if luminance>lightest then lightest,light=luminance,index end
      end
    end
    assert(dark~=nil,"В палитре нет непрозрачного цвета для сетки.")
  end
  local edge={}
  for y,row in ipairs(mask.rows) do
    for _,x in ipairs(row) do
      local sx,sy=mask.bounds.x+x,mask.bounds.y+y-1
      if not mask.selection:contains(sx-1,sy) or not mask.selection:contains(sx+1,sy)
        or not mask.selection:contains(sx,sy-1) or not mask.selection:contains(sx,sy+1) then
        edge[#edge+1]={x,y-1}
      end
    end
  end
  local cells=offsets(geometry)
  cells[#cells+1]={0,0}
  for _,p in ipairs(cells) do
    for _,point in ipairs(edge) do
      local x=mask.bounds.x+p[1]+point[1]-area.x
      local y=mask.bounds.y+p[2]+point[2]-area.y
      image:drawPixel(x,y,(not solid and (x+y)%2==0) and light or dark)
    end
  end
  return image
end

-- Независимые рисунки хранятся в документе, включая временно скрытые режимом REPEAT.
local function emptyNeighbors()
  return {modes={false,false,false,false,false,false},
    bases={"","","","","",""},drawings={"","","","","",""}}
end

local function readNeighbors(data, frame)
  local result, records=emptyNeighbors(),{}
  if data and data.neighbors then
    for i=1,#data.neighbors do
      local entry=data.neighbors[i]
      records[#records+1]={frame=entry.frame,payload=entry.payload}
      if entry.frame==frame then
        local state=json.decode(entry.payload)
        for n=1,6 do
          result.modes[n]=state.modes[n]==true
          result.bases[n]=state.bases[n]
          result.drawings[n]=state.drawings[n]
        end
      end
    end
  end
  return result,records
end

local function encodedImage(image)
  return (image.bytes:gsub(".",function(c)return string.format("%02x",c:byte())end))
end

local function decodedImage(sprite, mask, bytes)
  local image=transparentImage(sprite,mask.bounds.width,mask.bounds.height)
  local raw=bytes:gsub("..",function(pair)return string.char(tonumber(pair,16))end)
  assert(#raw==#image.bytes,"Размер сохранённой клетки отличается от маски.")
  image.bytes=raw
  return image
end

-- Заменяем только точные пиксели одной клетки, сохраняя всё остальное в исходном cel.
local function replaceRegion(sprite,layer,frame,mask,tile,protected)
  local cel=layer:cel(frame)
  local b=mask.bounds
  local left=cel and math.min(b.x,cel.position.x) or b.x
  local top=cel and math.min(b.y,cel.position.y) or b.y
  local right=cel and math.max(b.x+b.width,cel.position.x+cel.image.width) or b.x+b.width
  local bottom=cel and math.max(b.y+b.height,cel.position.y+cel.image.height) or b.y+b.height
  assert((right-left)*(bottom-top)<=16777216,"Исходный cel слишком велик для переключения клетки.")
  local image=transparentImage(sprite,right-left,bottom-top)
  if cel then image:drawImage(cel.image,Point(cel.position.x-left,cel.position.y-top)) end
  for y,row in ipairs(mask.rows) do
    for _,x in ipairs(row) do
      if not protected or not protected:contains(b.x+x,b.y+y-1) then
        image:drawPixel(b.x+x-left,b.y+y-1-top,tile:getPixel(x,y-1))
      end
    end
  end
  if cel then cel.image=image;cel.position=Point(left,top)
  else sprite:newCel(layer,frame,image,Point(left,top)) end
end

-- Производный слой обновляется без записи в Undo, исходный cel не затрагивается.
local function putDerived(cel, image)
  assert(cel.image.width==image.width and cel.image.height==image.height,
    "Размер служебного слоя изменился. Выключи и снова включи режим.")
  cel.image.bytes=image.bytes
  -- Уведомляем окна документа, включая Preview, не меняя видимость и историю Undo.
  local layer=cel.layer
  layer.isVisible=layer.isVisible
end

-- Не снимаем выделение, если пользователь уже заменил его собственным.
local function sameSelection(selection, mask)
  if selection.isEmpty then return false end
  local a, b = selection.bounds, mask.bounds
  if a.x ~= b.x or a.y ~= b.y or a.width ~= b.width or a.height ~= b.height then
    return false
  end
  for y = b.y, b.y + b.height - 1 do
    for x = b.x, b.x + b.width - 1 do
      if selection:contains(x, y) ~= mask.selection:contains(x, y) then return false end
    end
  end
  return true
end

-- Контроллер не зависит от окна и проверяется на нативных документах Aseprite.
function Hex.controller()
  local self = { enabled=false, closed=false, dirty=false, events=0,
    snapshots=0, tile=nil, error=nil, message="Выдели гекс и включи режим.", sessions={}, suspended={} }
  self.geometry, self.repeatOn = Hex.geometry(24,12,14), true
  self.gridOn=true
  self.gridOpacity,self.gridSolid=50,false
  self.neighborModes=emptyNeighbors().modes
  local binding, changeListener, saveListener

  local function editingMask(state)
    local selection=Selection()
    selection:add(binding.mask.selection)
    for i,p in ipairs(offsets(self.geometry)) do
      if state.modes[i] then selection:add(neighborMask(binding.mask,p).selection) end
    end
    return {selection=selection,bounds=selection.bounds}
  end

  local function blankCopies()
    if not binding or not binding.copies or not alive(binding.sprite) then return end
    pcall(function()
      local cel=binding.copies:cel(binding.frame)
      if cel then putDerived(cel,transparentImage(binding.sprite,cel.image.width,cel.image.height)) end
    end)
    pcall(function()
      if binding.grid then binding.grid.isVisible=false end
    end)
    app.refresh()
  end

  local function renderGrid()
    local cel=binding.grid:cel(binding.frame)
    if self.renderedGrid==self.gridOn and self.renderedGridId==cel.image.id
      and binding.grid.isVisible==self.gridOn then return end
    -- Штатная видимость уведомляет редактор, запись bytes этого не делает.
    binding.grid.isVisible=self.gridOn
    self.renderedGrid,self.renderedGridId=self.gridOn,cel.image.id
    app.refresh()
  end

  local function saveMask(state)
    state=state or binding.neighbors
    local m=binding.mask
    local rows={}
    for _,row in ipairs(m.rows) do
      local pixels={}
      for _,x in ipairs(row) do pixels[#pixels+1]=x end
      rows[#rows+1]=pixels
    end
    local cel=binding.copies:cel(binding.frame)
    local records={}
    for _,entry in ipairs(binding.records) do
      if entry.frame~=binding.frame then records[#records+1]=entry end
    end
    records[#records+1]={frame=binding.frame,payload=json.encode(state)}
    binding.copies.data=marker..json.encode{source=tostring(binding.layer.uuid),
      frame=binding.frame, x=m.bounds.x-cel.position.x, y=m.bounds.y-cel.position.y,
      width=m.bounds.width,height=m.bounds.height,rows=rows,
      stepX=self.geometry.stepX,rowX=self.geometry.rowX,rowY=self.geometry.rowY,neighbors=records}
  end

  local function prepareCopies()
    local sprite,source,mask=binding.sprite,binding.layer,binding.mask
    local area=Hex.footprint(mask,self.geometry)
    assert(area.width*area.height<=16777216,
      "Область повторов слишком велика. Уменьши смещения сетки.")
    local left,top=math.min(0,area.x),math.min(0,area.y)
    local right=math.max(sprite.width,area.x+area.width)
    local bottom=math.max(sprite.height,area.y+area.height)
    app.transaction("Hex Repeat: подготовка холста",function()
      if left<0 or top<0 or right>sprite.width or bottom>sprite.height then
        sprite:crop(left,top,right-left,bottom-top)
      end
      if not binding.copies then
        local copies=sprite:newLayer()
        copies.name="Hex Repeat — копии"
        copies.isEditable=false
        binding.copies=copies
      end
      local copies=binding.copies
      if copies.parent~=source.parent then copies.parent=source.parent end
      local index=source.stackIndex
      if copies.stackIndex<index then index=index-1 end
      if copies.stackIndex~=index then copies.stackIndex=index end
      copies.opacity=source.opacity
      copies.blendMode=source.blendMode
      copies.isVisible=true
      local position=Point(area.x-left,area.y-top)
      local image=transparentImage(sprite,area.width,area.height)
      local cel=copies:cel(binding.frame)
      if cel then cel.image=image;cel.position=position
      else sprite:newCel(copies,binding.frame,image,position) end
      local sourceCel=source:cel(binding.frame)
      copies:cel(binding.frame).opacity=sourceCel and sourceCel.opacity or 255
      -- Переносим маски вместе с содержимым расширенного холста.
      if left~=0 or top~=0 then
        local seen={}
        for _,session in ipairs(self.sessions) do
          if session.sprite==sprite and not seen[session.mask] then
            seen[session.mask]=true
            movedMask(session.mask,-left,-top)
          end
        end
      end
      sprite.useLayerUuids=true
      saveMask()
      -- Reference-слой использует исходный цветовой режим и палитру документа.
      if not binding.grid then
        app.command.NewLayer{reference=true,name="Hex Repeat — сетка",ask=false}
        binding.grid=app.layer
        assert(binding.grid.isReference,"Не удалось создать Reference-слой сетки.")
        binding.grid.data=gridMarker..tostring(source.uuid)
      end
      local grid=binding.grid
      if grid.parent~=sprite then grid.parent=sprite end
      grid.stackIndex=#sprite.layers
      grid.isEditable=false
      grid.isVisible=self.gridOn
      grid.opacity=math.floor(255*self.gridOpacity/100+0.5)
      binding.gridImage=Hex.gridImage(mask,self.geometry,sprite,binding.frame,self.gridSolid)
      if grid:cel(binding.frame) then sprite:deleteCel(grid,binding.frame) end
      -- Передаём готовый контур сразу, чтобы экран не закешировал пустой Reference-cel.
      local gridCel=sprite:newCel(grid,binding.frame,binding.gridImage,position)
      gridCel.data=self.gridSolid and solidGridMarker or ""
      sprite.selection=editingMask(binding.neighbors).selection
    end)
    app.layer=source
    app.frame=binding.frame
    binding.width,binding.height=sprite.width,sprite.height
    binding.opacity,binding.blend,binding.parent=source.opacity,source.blendMode,source.parent
    local sourceCel=source:cel(binding.frame)
    binding.celOpacity=sourceCel and sourceCel.opacity or 255
    self.copies=binding.copies
    self.grid=binding.grid
    self.renderedGrid,self.renderedGridId=nil,nil
  end

  function self.canConfigure()
    if not self.enabled then return true end
    for _,draw in ipairs(self.neighborModes) do if draw then return false end end
    for _,entry in ipairs(binding.records) do
      local state=json.decode(entry.payload)
      for i=1,6 do if state.modes[i] then return false end end
    end
    return true
  end

  function self.configure(geometry)
    local previous=self.geometry
    local nextGeometry=Hex.geometry(geometry.stepX,geometry.rowX,geometry.rowY)
    if previous.stepX==nextGeometry.stepX and previous.rowX==nextGeometry.rowX
      and previous.rowY==nextGeometry.rowY then return end
    if self.enabled then
      for _,entry in ipairs(binding.records) do
        local state=json.decode(entry.payload)
        for i=1,6 do
          assert(not state.modes[i],"Перед изменением смещений переключи DRAW в REPEAT во всех кадрах. Рисунки сохранятся.")
        end
      end
      for _,draw in ipairs(self.neighborModes) do
        assert(not draw,"Перед изменением смещений переключи клетки DRAW в REPEAT. Рисунки сохранятся.")
      end
    end
    self.geometry=nextGeometry
    if self.enabled then
      if app.sprite~=binding.sprite or app.layer~=binding.layer then self.disable();return end
      local bases=binding.neighbors.bases
      binding.neighbors.bases=emptyNeighbors().bases
      local ok,problem=pcall(prepareCopies)
      if not ok then binding.neighbors.bases=bases;self.geometry=previous;error(problem,0) end
      self.dirty=true
    end
  end

  function self.setRepeats(value)
    self.repeatOn=value==true
    self.dirty=true
  end

  function self.setGrid(value)
    self.gridOn=value==true
    if self.enabled and binding and alive(binding.sprite) then renderGrid() end
  end

  function self.getGridOpacity()
    if self.enabled and binding then
      self.gridOpacity=math.floor(binding.grid.opacity*100/255+0.5)
    end
    return self.gridOpacity
  end

  function self.setGridOpacity(value)
    assert(type(value)=="number" and value==math.floor(value) and value>=0 and value<=100,
      "Непрозрачность сетки должна быть от 0 до 100%.")
    self.gridOpacity=value
    if self.enabled and binding and alive(binding.sprite) then
      -- Непрозрачность меняет только служебный слой, индексы и палитра сохраняются.
      local opacity=math.floor(255*value/100+0.5)
      if binding.grid.opacity~=opacity then
        app.transaction("Hex Repeat: непрозрачность сетки",function()binding.grid.opacity=opacity end)
        app.refresh()
      end
    end
  end

  function self.getGridSolid()
    if self.enabled and binding then
      self.gridSolid=binding.grid:cel(binding.frame).data==solidGridMarker
    end
    return self.gridSolid
  end

  function self.setGridSolid(value)
    self.gridSolid=value==true
    if self.enabled and binding and alive(binding.sprite) then
      local cel=binding.grid:cel(binding.frame)
      local data=self.gridSolid and solidGridMarker or ""
      if cel.data~=data then
        -- Создаём готовую обводку в исходном формате, не затрагивая рисунок.
        local image=Hex.gridImage(binding.mask,self.geometry,binding.sprite,binding.frame,self.gridSolid)
        app.transaction("Hex Repeat: сплошной контур",function()cel.image=image;cel.data=data end)
        binding.gridImage=image
        app.refresh()
      end
    end
  end

  local function detach()
    if binding and changeListener and alive(binding.sprite) then
      pcall(function() binding.sprite.events:off(changeListener) end)
    end
    binding, changeListener = nil, nil
    if saveListener then app.events:off(saveListener);saveListener=nil end
  end

  function self.disable(keepMask)
    blankCopies()
    self.enabled = false
    if not keepMask and binding and alive(binding.sprite) then
      pcall(function()
        if binding.sprite.undoHistory.redoSteps==0
          and sameSelection(binding.sprite.selection, editingMask(binding.neighbors)) then
          binding.sprite.selection:deselect()
        end
      end)
    end
    detach()
    self.tile, self.pendingTile, self.lastBytes, self.dirty, self.copies = nil, nil, nil, false, nil
    self.sourceName = nil
    self.grid=nil
    self.message = "Режим выключен. Выбери слой."
  end

  -- Повторно используем подписки после возврата, не создавая слои и шаги Undo.
  local function attachBindingEvents()
    local sprite,layer=binding.sprite,binding.layer
    changeListener = sprite.events:on("change", function()
      if not self.closed then
        self.events = self.events + 1
        -- Undo/Redo возвращает режимы и сохранённые рисунки вместе с исходным cel.
        binding.neighbors,binding.records=readNeighbors(metadata(binding.copies),binding.frame)
        self.neighborModes=binding.neighbors.modes
        local ok,tile=pcall(Hex.captureNative,sprite,layer,binding.frame,binding.mask)
        if ok then self.pendingTile=tile;self.dirty=true
        else self.error="Не удалось прочитать рисунок. Нажми «Обновить»." end
      end
    end)
    saveListener=app.events:on("beforecommand",function(ev)
      if self.enabled and ev and (ev.name=="SaveFile" or ev.name=="SaveFileAs"
        or ev.name=="SaveFileCopyAs" or ev.name=="ExportSpriteSheet") then
        local ok,problem=pcall(function()self.flush(true)end)
        if not ok then self.disable();self.error=tostring(problem) end
      end
    end)
  end

  local function currentBinding(candidate)
    local ok,active=pcall(function()
      return app.sprite==candidate.sprite and app.layer==candidate.layer
        and app.frame and app.frame.frameNumber==candidate.frame
        and candidate.layer.isEditable and candidate.layer.isVisible
        and candidate.sprite.width==candidate.width and candidate.sprite.height==candidate.height
        and candidate.copies:cel(candidate.frame)~=nil and candidate.grid:cel(candidate.frame)~=nil
        and candidate.layer.opacity==candidate.opacity and candidate.layer.blendMode==candidate.blend
        and candidate.layer.parent==candidate.parent
        and (candidate.layer:cel(candidate.frame) and candidate.layer:cel(candidate.frame).opacity or 255)==candidate.celOpacity
    end)
    return ok and active
  end

  function self.suspend()
    if not self.enabled or not binding then return end
    local saved={binding=binding,geometry=self.geometry,repeatOn=self.repeatOn,
      gridOn=self.gridOn,gridOpacity=self.getGridOpacity(),gridSolid=self.getGridSolid()}
    self.disable(true)
    self.suspended[#self.suspended+1]=saved
    self.message="Режим приостановлен на другом холсте."
  end

  function self.enable(geometry)
    assert(not self.closed, "Панель уже закрыта.")
    local sprite, layer, frame = app.sprite, app.layer, app.frame
    assert(alive(sprite), "Открой холст и выбери слой.")
    local requestedMask
    if not sprite.selection.isEmpty then requestedMask=Selection();requestedMask:add(sprite.selection) end
    self.disable()
    -- Явное включение заменяет прежнюю приостановленную работу на этом документе.
    for i=#self.suspended,1,-1 do
      if self.suspended[i].binding.sprite==sprite then table.remove(self.suspended,i) end
    end
    assert(layer and not layer.isGroup and not layer.isTilemap and not layer.isReference,
      "Выбери обычный растровый слой.")
    assert(not metadata(layer),"Выбери исходный слой, а не служебные копии.")
    assert(not layer.isBackground,"Преобразуй Background в обычный слой с прозрачностью.")
    assert(sprite.colorMode == ColorMode.RGB or sprite.colorMode == ColorMode.INDEXED,
      "Поддерживаются RGB и Indexed.")
    assert(layer.isEditable and layer.isVisible, "Разблокируй и покажи выбранный слой.")
    local saved
    for _, item in ipairs(self.sessions) do
      if item.sprite == sprite and item.layer == layer then saved = item end
    end
    local copies,data=findCopies(sprite,layer)
    local neighbors,records=readNeighbors(data,frame.frameNumber)
    local persistedMask
    if copies and data and (copies:cel(frame) or copies:cel(data.frame)) then
      local cel=copies:cel(frame) or copies:cel(data.frame)
      local shape=Selection()
      for y=1,#data.rows do
        local row=data.rows[y]
        for i=1,#row do shape:add(Rectangle(cel.position.x+data.x+row[i],
          cel.position.y+data.y+y-1,1,1)) end
      end
      persistedMask=Hex.mask(shape,sprite)
    end
    -- Не принимаем собственное объединённое выделение за новую центральную клетку.
    if requestedMask and saved then
      local union=Selection()
      union:add(saved.mask.selection)
      for i,p in ipairs(offsets(data and Hex.geometry(data.stepX,data.rowX,data.rowY) or self.geometry)) do
        if neighbors.modes[i] then union:add(neighborMask(saved.mask,p).selection) end
      end
      if sameSelection(requestedMask,{selection=union,bounds=union.bounds}) then requestedMask=nil end
    elseif requestedMask and persistedMask then
      local union=Selection()
      union:add(persistedMask.selection)
      for i,p in ipairs(offsets(Hex.geometry(data.stepX,data.rowX,data.rowY))) do
        if neighbors.modes[i] then union:add(neighborMask(persistedMask,p).selection) end
      end
      if sameSelection(requestedMask,{selection=union,bounds=union.bounds}) then requestedMask=nil end
    end
    if requestedMask and persistedMask and not sameSelection(requestedMask,persistedMask) then
      for _,entry in ipairs(records) do
        local state=json.decode(entry.payload)
        for i=1,6 do
          assert(not state.modes[i] and state.drawings[i]=="",
            "У слоя есть самостоятельные клетки. Для другой центральной маски используй новый исходный слой.")
        end
      end
    end
    local mask
    if requestedMask then
      mask = Hex.mask(requestedMask, sprite)
    elseif saved then
      mask = Hex.mask(saved.mask.selection, sprite)
    elseif persistedMask then
      mask=persistedMask
    else
      error("Выдели точную форму одного гекса.", 0)
    end
    if saved then saved.mask = mask
    else self.sessions[#self.sessions + 1] = { sprite=sprite, layer=layer, mask=mask } end
    self.geometry=geometry or (data and Hex.geometry(data.stepX,data.rowX,data.rowY))
      or Hex.geometry(mask.bounds.width,self.geometry.rowX,self.geometry.rowY)
    binding = { sprite=sprite, layer=layer, frame=frame.frameNumber, mask=mask,copies=copies,
      neighbors=neighbors,records=records,grid=findGrid(sprite,layer) }
    self.neighborModes=neighbors.modes
    local prepared,problem=pcall(prepareCopies)
    if not prepared then detach();error(problem,0) end
    -- Снимаем готовый рисунок после изменения, обработчик только читает документ.
    attachBindingEvents()
    self.pendingTile=Hex.captureNative(sprite,layer,binding.frame,binding.mask)
    self.enabled, self.dirty, self.error = true, true, nil
    self.sourceName = layer.name
    self.message = "Рисуй на основном холсте."
  end

  function self.resume()
    if self.enabled or self.closed then return false end
    for i=#self.suspended,1,-1 do
      local saved=self.suspended[i]
      local candidate=saved.binding
      if not alive(candidate.sprite) then table.remove(self.suspended,i)
      elseif app.sprite==candidate.sprite and app.layer==candidate.layer
        and app.frame and app.frame.frameNumber==candidate.frame then
        table.remove(self.suspended,i)
        -- Изменённый холст, удалённые слои и отменённую подготовку не восстанавливаем.
        if not currentBinding(candidate) then return false end
        local ok,tile,neighbors,records=pcall(function()
          local n,r=readNeighbors(metadata(candidate.copies),candidate.frame)
          return Hex.captureNative(candidate.sprite,candidate.layer,candidate.frame,candidate.mask),n,r
        end)
        if not ok then self.error="Не удалось восстановить Hex Repeat. Включи режим вручную.";return false end
        binding=candidate
        self.geometry,self.repeatOn=saved.geometry,saved.repeatOn
        self.gridOn,self.gridOpacity,self.gridSolid=saved.gridOn,saved.gridOpacity,saved.gridSolid
        binding.neighbors,binding.records=neighbors,records
        self.neighborModes=neighbors.modes
        self.pendingTile,self.tile,self.lastBytes=tile,nil,nil
        self.copies,self.grid,self.sourceName=binding.copies,binding.grid,binding.layer.name
        self.renderedGrid,self.renderedGridId=nil,nil
        attachBindingEvents()
        self.enabled,self.dirty,self.error=true,true,nil
        self.message="Режим восстановлен. Рисуй на холсте."
        return true
      end
    end
    return false
  end

  function self.flush(poll)
    if self.closed or not self.enabled then return false end
    -- Сначала исключаем удалённый документ, затем обращаемся к его объектам.
    if not alive(binding.sprite) then
      self.disable()
      self.message = "Открой холст и включи режим."
      return false
    end
    if app.sprite~=binding.sprite then self.suspend();return false end
    if not currentBinding(binding) then
      self.disable()
      self.message = "Холст или слой сменился. Включи режим."
      return false
    end
    renderGrid()
    if not self.dirty and not poll then return false end
    -- При удержании кисти cel может быть промежуточным. Таймер его не перечитывает.
    -- Пустой снимок от завершённого изменения при этом остаётся настоящим удалением.
    local tile = self.pendingTile or self.tile
    if not tile then return false end
    local bytes = tile.bytes
    local dirty=self.dirty
    self.dirty = false
    local output=binding.copies:cel(binding.frame)
    -- Сверяем также производный cel после Undo/Redo и ручных команд пользователя.
    if bytes == self.lastBytes and not dirty and self.renderedRepeat==self.repeatOn
      and self.renderedId==output.image.id then return false end
    local image=transparentImage(binding.sprite,output.image.width,output.image.height)
    if self.repeatOn then
      local g,m=self.geometry,binding.mask
      for i,p in ipairs(offsets(g)) do
        if not self.neighborModes[i] then
          image:drawImage(tile,Point(m.bounds.x+p[1]-output.position.x,
            m.bounds.y+p[2]-output.position.y))
        end
      end
      -- Копии не заполняют прозрачные отверстия центра и самостоятельных клеток.
      local clear=binding.sprite.colorMode==ColorMode.INDEXED and binding.sprite.transparentColor or 0
      local function clearMask(mask)
        for y,row in ipairs(mask.rows) do
          for _,x in ipairs(row) do image:drawPixel(mask.bounds.x+x-output.position.x,
            mask.bounds.y+y-1-output.position.y,clear) end
        end
      end
      clearMask(m)
      for i,p in ipairs(offsets(g)) do
        if self.neighborModes[i] then clearMask(neighborMask(m,p)) end
      end
    end
    putDerived(output,image)
    self.renderedRepeat,self.renderedId=self.repeatOn,output.image.id
    self.tile, self.lastBytes = tile, bytes
    self.snapshots = self.snapshots + 1
    app.refresh()
    return true
  end

  function self.toggleNeighbor(index)
    assert(self.enabled and binding,"Сначала включи режим Hex Repeat.")
    assert(index>=1 and index<=6,"Неизвестная соседняя клетка.")
    assert(app.sprite==binding.sprite and app.layer==binding.layer,
      "Выбери исходный слой.")
    local positions=offsets(self.geometry)
    local state=emptyNeighbors()
    for i=1,6 do
      state.modes[i]=binding.neighbors.modes[i]
      state.bases[i]=binding.neighbors.bases[i]
      state.drawings[i]=binding.neighbors.drawings[i]
    end
    local sprite,source,frame=binding.sprite,binding.layer,binding.frame
    local hasDraw=false
    for _,draw in ipairs(state.modes) do if draw then hasDraw=true;break end end
    -- До первого DRAW запоминаем общий исходный фон всех соседей.
    -- Так пересечение не сохраняет чужой временный рисунок как исходный фон.
    if not hasDraw then
      for i,p in ipairs(positions) do
        state.bases[i]=encodedImage(Hex.captureNative(sprite,source,frame,neighborMask(binding.mask,p)))
      end
    else
      -- В старых документах фон запоминался отдельно при включении каждого соседа.
      -- Недостающие снимки восстанавливаем из исходного cel и фонов активных клеток.
      for i,p in ipairs(positions) do
        if state.bases[i]=="" then
          local target=neighborMask(binding.mask,p)
          local base=Hex.captureNative(sprite,source,frame,target)
          for j,q in ipairs(positions) do
            if state.modes[j] then
              local active=neighborMask(binding.mask,q)
              local original=decodedImage(sprite,active,state.bases[j])
              for y,row in ipairs(active.rows) do
                for _,x in ipairs(row) do
                  local sx,sy=active.bounds.x+x,active.bounds.y+y-1
                  if target.selection:contains(sx,sy) then
                    base:drawPixel(sx-target.bounds.x,sy-target.bounds.y,original:getPixel(x,y-1))
                  end
                end
              end
            end
          end
          state.bases[i]=encodedImage(base)
        end
      end
    end
    local mask=neighborMask(binding.mask,positions[index])
    local current=Hex.captureNative(sprite,source,frame,mask)
    local protected=editingMask(state).selection
    local replacement
    if state.modes[index] then
      state.drawings[index]=encodedImage(current)
      replacement=decodedImage(sprite,mask,state.bases[index])
    else
      if state.drawings[index]~="" then
        replacement=decodedImage(sprite,mask,state.drawings[index])
      else
        replacement=Hex.captureNative(sprite,source,frame,binding.mask)
        replacement:drawImage(current)
      end
    end
    state.modes[index]=not state.modes[index]
    -- При выключении сохраняем всё, что по-прежнему принадлежит центру или DRAW.
    if not state.modes[index] then protected=editingMask(state).selection end
    app.transaction("Hex Repeat: REPEAT / DRAW",function()
      replaceRegion(sprite,source,frame,mask,replacement,protected)
      saveMask(state)
      sprite.selection=editingMask(state).selection
    end)
    binding.neighbors=state
    self.neighborModes=state.modes
    self.pendingTile=Hex.captureNative(sprite,source,frame,binding.mask)
    self.dirty=true
  end

  -- Явное обновление выполняется по кнопке панели, вне рисования на холсте.
  function self.refreshSource()
    assert(self.enabled and binding and alive(binding.sprite),"Сначала включи режим.")
    self.pendingTile=Hex.captureNative(binding.sprite,binding.layer,binding.frame,binding.mask)
    self.dirty=true
  end

  function self.restoreMask()
    assert(self.enabled and binding and alive(binding.sprite), "Сначала включи режим.")
    assert(app.sprite == binding.sprite and app.layer == binding.layer,
      "Выбери исходный слой.")
    binding.sprite.selection = editingMask(binding.neighbors).selection
  end

  function self.close()
    if self.closed then return end
    self.disable()
    self.closed = true
    self.sessions = {}
    self.suspended = {}
  end
  return self
end

-- В пакетной проверке возвращаем тот же контроллер без имитации модели изображения.
if app.params.module == "1" then return Hex end

if app.params.selftest == "1" then
  local sprite = Sprite(8, 8, ColorMode.RGB)
  local shape = Selection(Rectangle(2, 3, 2, 1))
  shape:add(Rectangle(2, 4, 1, 1))
  local image = Image(2, 2, ColorMode.RGB)
  local color = app.pixelColor.rgba(120, 200, 40, 255)
  image:clear(color)
  sprite:newCel(sprite.layers[1], 1, image, Point(2, 3))
  local result = Hex.capture(sprite, sprite.layers[1], 1, Hex.mask(shape, sprite))
  assert(result:getPixel(0, 0) == color and result:getPixel(1, 1) == 0)
  if app.params.report then
    local report = assert(io.open(app.params.report, "w"))
    report:write("PASS: exact mask, cel offset, RGBA capture\n")
    report:close()
  end
  sprite:close()
  return
end

-- Повторный запуск не создаёт второй таймер и конкурирующую панель.
if _G.hexRepeatPanel then
  _G.hexRepeatPanel:close()
end
if not app.isUIAvailable then return Hex end

local controller = Hex.controller()
local dialog, timer
local closing, busy = false, false
local requested, restoreRequested, refreshRequested = nil, false, false
local displayedMode, modeNeedsSync = false, false
local pendingRepeat, pendingNeighbor, pendingGrid, pendingGridOpacity, pendingGridSolid
local displayedOpacity, displayedSolid, gridControlsVisible=50,false,true
local displayedGeometry="24,12,14"
local errorText = nil
local displayedError, copyNote = nil, nil
local errorScroll = 0
local errorCopyX = 218
local ticks = 0

local function cleanup()
  if closing then return end
  closing = true
  if timer then timer:stop() end
  controller.close()
  if _G.hexRepeatPanel == dialog then _G.hexRepeatPanel = nil end
end

-- Ошибки остаются в панели. Автоматических модальных окон при рисовании нет.
local function run(action, clearError)
  local ok, problem = pcall(action)
  if not ok then
    errorText = tostring(problem):gsub("^.-:%d+: ", "")
    return false
  end
  if clearError~=false then errorText = nil end
  return true
end

-- Текст рисуется в фиксированной области и не меняет ширину панели.
local function paintStatus(ev)
  local gc = ev.context
  gc.color = Color{ r=35, g=35, b=35 }
  gc:fillRect(Rectangle(0, 0, gc.width, gc.height))
  gc.color = Color{r=220,g=220,b=220}
  gc:fillText(controller.message, 4, 3)
  gc.color = Color{ r=180,g=180,b=180 }
  gc:fillText(controller.sourceName and ("Слой: " .. controller.sourceName) or "Слой не привязан", 4, 17)
end

-- Переносим UTF-8 по словам и измеряем реальным шрифтом панели, длинные слова делим.
local function errorLines(gc,width)
  local lines={}
  for paragraph in ((errorText or "").."\n"):gmatch("(.-)\n") do
    local line=""
    for word in paragraph:gmatch("%S+") do
      local nextLine=line=="" and word or line.." "..word
      if gc:measureText(nextLine).width<=width then line=nextLine
      else
        if line~="" then lines[#lines+1]=line;line="" end
        for _,code in utf8.codes(word) do
          local char=utf8.char(code)
          if line~="" and gc:measureText(line..char).width>width then
            lines[#lines+1]=line;line=""
          end
          line=line..char
        end
      end
    end
    lines[#lines+1]=line
  end
  return lines
end

-- Полная ошибка доступна здесь, длинный текст прокручивается колёсиком.
local function paintError(ev)
  local gc=ev.context
  gc.color=Color{r=35,g=35,b=35}
  gc:fillRect(Rectangle(0,0,gc.width,gc.height))
  gc.color=errorText and Color{r=255,g=150,b=100} or Color{r=150,g=150,b=150}
  gc:fillText(errorText and "Ошибка" or "Ошибок нет",4,3)
  local lines=errorLines(gc,math.max(16,gc.width-8))
  local lineHeight=math.max(14,gc:measureText("Ag").height+2)
  local count=math.max(1,math.floor((gc.height-32)/lineHeight))
  errorScroll=math.max(0,math.min(errorScroll,#lines-count))
  if errorText then
    for i=1,count do
      local text=lines[errorScroll+i]
      if text then gc:fillText(text,4,17+(i-1)*lineHeight) end
    end
  end
  gc.color=Color{r=180,g=180,b=180}
  if copyNote then gc:fillText(copyNote,4,gc.height-12)
  elseif #lines>count then
    gc:fillText(string.format("%d–%d / %d, прокрутка колёсиком",errorScroll+1,
      math.min(#lines,errorScroll+count),#lines),4,gc.height-12)
  end
  -- Два листка обозначают копирование, фон и контур образуют маленькую кнопку.
  local x=gc.width-22
  errorCopyX=x
  gc.color=Color{r=90,g=90,b=90}
  gc:fillRect(Rectangle(x,1,20,15))
  gc.color=Color{r=50,g=50,b=50}
  gc:fillRect(Rectangle(x+1,2,18,13))
  gc.color=errorText and Color{r=230,g=230,b=230} or Color{r=100,g=100,b=100}
  gc:fillRect(Rectangle(x+5,4,7,8))
  gc:fillRect(Rectangle(x+8,6,7,8))
  gc.color=Color{r=50,g=50,b=50}
  gc:fillRect(Rectangle(x+9,7,5,6))
end

local function copyError()
  if not errorText then return end
  local ok=pcall(function()app.clipboard.text="Hex Repeat\n"..errorText end)
  copyNote=ok and "Ошибка скопирована" or "Не удалось скопировать ошибку"
  dialog:repaint()
end

local diagramCenters={{88,28},{152,28},{56,70},{184,70},{88,112},{152,112},{120,70}}

-- Это схема управления, её форма не заменяет пользовательскую маску на холсте.
local function diagramContains(x,y,center)
  local dx,dy=math.abs(x-center[1]),math.abs(y-center[2])
  return dy<=26 and dx<=math.min(30,30*(26-dy)/13)
end

local function paintDiagram(ev)
  local gc=ev.context
  gc.color=Color{r=35,g=35,b=35}
  gc:fillRect(Rectangle(0,0,gc.width,gc.height))
  for i,c in ipairs(diagramCenters) do
    local draw=i<=6 and controller.neighborModes[i]
    local fill=i==7 and Color{r=80,g=80,b=80}
      or (draw and Color{r=60,g=110,b=75} or Color{r=55,g=80,b=115})
    for y=-26,26 do
      local half=math.floor(math.min(30,30*(26-math.abs(y))/13))
      gc.color=Color{r=155,g=155,b=155}
      gc:fillRect(Rectangle(c[1]-half,c[2]+y,half*2+1,1))
      if half>2 and math.abs(y)<24 then
        gc.color=fill
        gc:fillRect(Rectangle(c[1]-half+2,c[2]+y,half*2-3,1))
      end
    end
    gc.color=controller.enabled and Color{r=240,g=240,b=240} or Color{r=150,g=150,b=150}
    local label=i==7 and "Центр" or (draw and "Рисовать" or "Повтор")
    -- Центрируем подпись по реальному размеру текста в текущем шрифте.
    local size=gc:measureText(label)
    gc:fillText(label,math.floor(c[1]-size.width/2),math.floor(c[2]-size.height/2))
  end
end

dialog = Dialog{ title="Hex Repeat", resizeable=true, onclose=cleanup }
_G.hexRepeatPanel = dialog
dialog:separator{ id="infoHeading", label="Информация гексагона", text="Опции" }
dialog:newrow()
dialog:check{ id="mode", label="Шаг X: 24", text="Режим Hex Repeat", selected=false,
  onclick=function() requested = dialog.data.mode; modeNeedsSync=true end }
dialog:newrow()
dialog:check{ id="repeatOn", label="Сдвиг ряда X: 12", text="Показывать повторы", selected=true,
  onclick=function() pendingRepeat=dialog.data.repeatOn end }
dialog:newrow()
dialog:check{ id="gridOn", label="Шаг ряда Y: 14", text="Показывать сетку", selected=true,
  onclick=function()pendingGrid=dialog.data.gridOn end }
dialog:newrow()
dialog:check{ id="gridSolid", text="Сплошной контур", selected=false,
  onclick=function()pendingGridSolid=dialog.data.gridSolid end }
dialog:newrow()
dialog:label{ id="gridOpacityTitle", text="Непрозрачность, %", hexpand=false }
dialog:samerow()
dialog:slider{ id="gridOpacity", min=0, max=100, value=50,
  onchange=function()pendingGridOpacity=dialog.data.gridOpacity end }
dialog:newrow()
dialog:canvas{ id="neighbors", width=240, height=142, hexpand=false, vexpand=false,
  onpaint=paintDiagram, onmouseup=function(ev)
    if not controller.enabled or ev.button~=MouseButton.LEFT then return end
    for i=1,6 do
      if diagramContains(ev.x,ev.y,diagramCenters[i]) then pendingNeighbor=i;return end
    end
  end }
dialog:newrow()
dialog:check{ id="poll", text="Опрос при рисовании", selected=false }
dialog:newrow()
dialog:canvas{ id="status", width=240, height=32, vexpand=false, onpaint=paintStatus }
dialog:newrow()
dialog:canvas{ id="error", width=240, height=90, vexpand=false,
  onpaint=paintError, onwheel=function(ev)
    if errorText then errorScroll=errorScroll+(ev.deltaY>0 and 1 or (ev.deltaY<0 and -1 or 0));dialog:repaint() end
  end,
  onmouseup=function(ev)
    if ev.button==MouseButton.LEFT and ev.x>=errorCopyX and ev.x<errorCopyX+20
      and ev.y>=1 and ev.y<16 then copyError() end
  end }
dialog:newrow()
dialog:button{ text="Вернуть маску", onclick=function() restoreRequested=true end }
dialog:button{ text="Обновить", onclick=function() refreshRequested=true end }
dialog:newrow()
dialog:button{ text="Закрыть", label="Версия "..Hex.version, onclick=function() dialog:close() end }

-- Таймер обновляет только представление и контроллер, после событий документа.
timer = Timer{ interval=0.1, ontick=function()
  if closing or busy then return end
  busy = true
  ticks = ticks + 1
  local ok, problem = pcall(function()
    if requested ~= nil then
      local activate = requested
      requested = nil
      if activate then
        run(function()
          controller.setRepeats(dialog.data.repeatOn)
          controller.setGrid(dialog.data.gridOn)
          controller.setGridOpacity(dialog.data.gridOpacity)
          controller.setGridSolid(dialog.data.gridSolid)
          controller.enable()
          controller.flush(true)
        end)
      else run(controller.disable) end
    end
    if pendingRepeat~=nil then
      controller.setRepeats(pendingRepeat)
      pendingRepeat=nil
    end
    if pendingGrid~=nil then
      local show=pendingGrid
      pendingGrid=nil
      run(function()controller.setGrid(show)end)
    end
    if pendingGridOpacity~=nil then
      local value=pendingGridOpacity
      pendingGridOpacity=nil
      run(function()controller.setGridOpacity(value)end)
    end
    if pendingGridSolid~=nil then
      local value=pendingGridSolid
      pendingGridSolid=nil
      run(function()controller.setGridSolid(value)end)
    end
    if pendingNeighbor then
      local index=pendingNeighbor
      pendingNeighbor=nil
      run(function()controller.toggleNeighbor(index)end)
    end
    if restoreRequested then restoreRequested=false; run(controller.restoreMask) end
    if refreshRequested then refreshRequested=false; run(controller.refreshSource) end
    if controller.enabled then
      if not run(function() controller.flush(dialog.data.poll or ticks % 10 == 0) end,false) then
        controller.disable()
      end
    end
    if not controller.enabled then
      run(function()
        if controller.resume() then
          controller.flush(true)
          if controller.enabled then
            dialog:modify{id="repeatOn",selected=controller.repeatOn}
            dialog:modify{id="gridOn",selected=controller.gridOn}
          end
        end
      end,false)
    end
    -- Не стираем нативное нажатие между MouseDown и onclick очередным тиком таймера.
    if modeNeedsSync or displayedMode~=controller.enabled then
      dialog:modify{ id="mode", selected=controller.enabled }
      displayedMode,modeNeedsSync=controller.enabled,false
    end
    if controller.error then errorText=controller.error;controller.error=nil end
    -- Настройки появляются под галочкой сетки, Undo/Redo возвращает их значения.
    local showGridControls=dialog.data.gridOn
    if gridControlsVisible~=showGridControls then
      gridControlsVisible=showGridControls
      dialog:modify{id="gridSolid",visible=showGridControls}
      dialog:modify{id="gridOpacityTitle",visible=showGridControls}
      dialog:modify{id="gridOpacity",visible=showGridControls}
    end
    local transparency=controller.getGridOpacity()
    if displayedOpacity~=transparency then
      displayedOpacity=transparency
      dialog:modify{id="gridOpacity",value=transparency}
    end
    local solid=controller.getGridSolid()
    if displayedSolid~=solid then
      displayedSolid=solid
      dialog:modify{id="gridSolid",selected=solid}
    end
    -- Значения только поясняют текущую сетку, обработчиков ввода у них нет.
    local geometry=controller.geometry
    local key=table.concat({geometry.stepX,geometry.rowX,geometry.rowY},",")
    if displayedGeometry~=key then
      displayedGeometry=key
      dialog:modify{id="mode",label=string.format("Шаг X: %d",geometry.stepX)}
      dialog:modify{id="repeatOn",label=string.format("Сдвиг ряда X: %d",geometry.rowX)}
      dialog:modify{id="gridOn",label=string.format("Шаг ряда Y: %d",geometry.rowY)}
    end
    if displayedError~=errorText then
      displayedError=errorText
      errorScroll,copyNote=0,nil
    end
    dialog:repaint()
  end)
  busy = false
  if not ok then
    errorText = tostring(problem)
    -- Не пытаемся перерисовывать повреждённое окно из его обработчика ошибки.
    timer:stop()
    controller.close()
    print("Hex Repeat: " .. errorText)
  end
end }
dialog:show{ wait=false, autoscrollbars=true }
timer:start()
return Hex
