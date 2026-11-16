-- Редактор экрана ZX Spectrum на штатном индексном холсте Aseprite.
-- SCR хранится в свойствах документа, 6144 байта пикселей и 768 атрибутов.
-- FLASH сохраняется в SCR, но не воспроизводится и не редактируется.

local ZX = {}
local PROPERTY = "codex/zx-spectrum-screen"
local WIDTH, HEIGHT, SCR_SIZE = 256, 192, 6912

-- Рассчитываем физическое смещение строки в битовой плоскости Spectrum.
local function bitmapOffset(x, y)
  return ((y & 192) << 5) + ((y & 7) << 8) + ((y & 56) << 2) + (x >> 3) + 1
end

local function attrOffset(x, y)
  return 6145 + (y >> 3) * 32 + (x >> 3)
end

-- Преобразуем физические байты без изменения их порядка и значений.
function ZX.decode(bytes)
  assert(type(bytes) == "string" and #bytes == SCR_SIZE, "SCR must contain exactly 6912 bytes")
  local result = {}
  for i = 1, SCR_SIZE do result[i] = bytes:byte(i) end
  return result
end

function ZX.encode(screen)
  local chunks = {}
  for first = 1, SCR_SIZE, 256 do
    chunks[#chunks + 1] = string.char(table.unpack(screen, first, math.min(first + 255, SCR_SIZE)))
  end
  return table.concat(chunks)
end

-- Определяем логическую принадлежность пикселя независимо от видимого цвета.
function ZX.pixel(screen, x, y)
  local ink = (screen[bitmapOffset(x, y)] & (128 >> (x & 7))) ~= 0
  local attr = screen[attrOffset(x, y)]
  local shade = (ink and (attr & 7) or ((attr >> 3) & 7)) + ((attr & 64) >> 3)
  return shade, ink, attr
end

-- Изменяем бит пикселя и один цвет атрибута, BRIGHT берётся из рисующего цвета.
function ZX.paint(screen, x, y, ink, shade)
  local offset = bitmapOffset(x, y)
  local mask = 128 >> (x & 7)
  if ink then
    screen[offset] = screen[offset] | mask
  else
    screen[offset] = screen[offset] & (255 ~ mask)
  end
  local attrIndex = attrOffset(x, y)
  local attr = screen[attrIndex]
  if ink then
    attr = (attr & 184) | (shade & 7)
  else
    attr = (attr & 135) | ((shade & 7) << 3)
  end
  screen[attrIndex] = attr | ((shade & 8) << 3)
end

-- Создаём цвета в спектрумовском порядке B, R, G с двумя уровнями яркости.
function ZX.color(shade)
  local level = shade >= 8 and 255 or 205
  return Color {
    r = (shade & 2) ~= 0 and level or 0,
    g = (shade & 4) ~= 0 and level or 0,
    b = (shade & 1) ~= 0 and level or 0
  }
end

-- Создаём справочную палитру Spectrum, к пользовательскому документу она не применяется.
function ZX.palette()
  local palette = Palette(16)
  for shade = 0, 15 do
    palette:setColor(shade, ZX.color(shade))
  end
  return palette
end

-- Рассчитываем ближайший спектрумовский цвет для текущего цвета кисти.
local function nearest(color)
  local best, distance = 0, math.huge
  for shade = 0, 15 do
    local candidate = ZX.color(shade)
    local delta = (color.red - candidate.red) ^ 2 +
      (color.green - candidate.green) ^ 2 + (color.blue - candidate.blue) ^ 2
    if delta < distance then best, distance = shade, delta end
  end
  return best
end

-- Проверяем цвет существующего рисунка без автоматического ухудшения палитры.
local function existingShade(color)
  if color.alpha ~= 255 then return nil end
  local level = math.max(color.red, color.green, color.blue)
  if level ~= 0 and level ~= 192 and level ~= 205 and level ~= 215 and level ~= 255 then
    return nil
  end
  for _, value in ipairs { color.red, color.green, color.blue } do
    if value ~= 0 and value ~= level then return nil end
  end
  return (color.blue > 0 and 1 or 0) + (color.red > 0 and 2 or 0) +
    (color.green > 0 and 4 or 0) + (level == 255 and 8 or 0)
end

-- Сопоставляем цвета с существующими индексами, не меняя общую палитру документа.
local function paletteView(sprite)
  local palette = sprite.palettes[1]
  local view = { indices = {}, shades = {}, transparent = sprite.transparentColor }
  local standard = #palette == 16
  for index = 0, #palette - 1 do
    local color = palette:getColor(index)
    local shade = existingShade(color)
    view.shades[index] = shade
    if standard and (shade == nil or (shade & 7) ~= (index & 7) or
      ((index & 7) ~= 0 and (shade & 8) ~= (index & 8))) then standard = false end
  end
  if standard then
    -- Два чёрных имеют одинаковый RGB, их BRIGHT определяется позицией в палитре.
    for index = 0, 15 do view.shades[index] = index end
  end
  for index = 0, #palette - 1 do
    local shade = view.shades[index]
    if shade ~= nil and index ~= view.transparent and view.indices[shade] == nil then
      view.indices[shade] = index
    end
  end
  -- Один непрозрачный чёрный может отображать обе яркости, BRIGHT хранится в SCR.
  view.indices[0] = view.indices[0] or view.indices[8]
  view.indices[8] = view.indices[8] or view.indices[0]
  return view
end

local function indexedImage(transparent)
  local image = Image(ImageSpec {
    width = WIDTH, height = HEIGHT, colorMode = ColorMode.INDEXED,
    transparentColor = transparent
  })
  image:clear(transparent)
  return image
end

local function displayIndex(view, shade)
  local index = view.indices[shade]
  assert(index ~= nil, "В текущей палитре нет непрозрачного цвета Spectrum с кодом " .. shade .. ".")
  return index
end

-- Перечисляем слои ZX снизу вверх, полупрозрачные слои и группы служат подложками.
local function imageLayers(sprite)
  local result = {}
  local function visit(layers, visible)
    for _, layer in ipairs(layers) do
      local shown = visible and layer.isVisible
      if layer.isGroup then
        -- У обычной проходной группы Aseprite не предоставляет свойство opacity.
        if layer.opacity == nil or layer.opacity == 255 then visit(layer.layers, shown) end
      elseif layer.opacity == 255 then
        assert(layer.isImage and not layer.isReference and not layer.isTilemap,
          "Режим ZX поддерживает обычные растровые слои и группы.")
        assert(layer.blendMode == BlendMode.NORMAL, "Для ZX нужен режим смешивания Normal.")
        result[#result + 1] = { layer = layer, visible = shown }
      end
    end
  end
  visit(sprite.layers, true)
  return result
end

-- Проверяем размер, индексный формат и наличие единственного экрана анимации.
local function validate(sprite)
  assert(sprite.width == WIDTH and sprite.height == HEIGHT, "Нужен размер 256×192.")
  assert(sprite.colorMode == ColorMode.INDEXED, "Нужен режим Indexed.")
  assert(#sprite.frames == 1, "Пока поддерживается один кадр, число обычных слоёв не ограничено.")
  assert(#imageLayers(sprite) > 0, "Нужен хотя бы один обычный слой с непрозрачностью 100%.")
end

-- Получаем изображение слоя в координатах холста, сохраняя его прозрачные пиксели.
local function captureLayer(sprite, layer)
  local image = indexedImage(sprite.transparentColor)
  local cel = layer:cel(1)
  if cel then image:drawImage(cel.image, cel.position) end
  return image
end

-- Преобразуем физический экран в обычные индексы видимых цветов.
function ZX.render(screen, view)
  view = view or paletteView(app.activeSprite)
  local image = indexedImage(view.transparent)
  for y = 0, HEIGHT - 1 do
    for x = 0, WIDTH - 1 do image:drawPixel(x, y, displayIndex(view, ZX.pixel(screen, x, y))) end
  end
  return image
end

-- Создаём нулевую битовую плоскость с общей таблицей атрибутов документа.
local function blankPlane(common, view)
  local screen, mask = {}, {}
  for i = 1, 6144 do screen[i], mask[i] = 0, 0 end
  for i = 6145, SCR_SIZE do screen[i] = common[i] end
  return { screen = screen, mask = mask, overrides = {}, view = view }
end

-- Проверяем покрытие слоя независимо от логического значения INK/PAPER.
local function covered(model, x, y)
  return (model.mask[bitmapOffset(x, y)] & (128 >> (x & 7))) ~= 0
end

local function renderPlane(model)
  local image = indexedImage(model.view.transparent)
  for y = 0, HEIGHT - 1 do
    for x = 0, WIDTH - 1 do
      if covered(model, x, y) then
        local shade = model.overrides[1 + y * WIDTH + x] or ZX.pixel(model.screen, x, y)
        image:drawPixel(x, y, displayIndex(model.view, shade))
      end
    end
  end
  return image
end

-- Отображаем отдельные составляющие, сохраняя покрытие и настоящие биты в модели.
local function renderChannels(model, channels)
  if channels.ink and channels.paper and channels.bright then return renderPlane(model) end
  local image = indexedImage(model.view.transparent)
  for y = 0, HEIGHT - 1 do
    for x = 0, WIDTH - 1 do
      if covered(model, x, y) then
        local shade, ink, attr = ZX.pixel(model.screen, x, y)
        if channels.ink and not channels.paper then
          shade = ink and 0 or (channels.bright and (attr & 64) ~= 0 and 15 or 7)
        elseif channels.paper then
          if not channels.ink then shade = ((attr >> 3) & 7) | ((attr & 64) >> 3)
          else shade = model.overrides[1 + y * WIDTH + x] or shade end
          if not channels.bright then shade = shade & 7 end
        elseif channels.bright then
          shade = (attr & 64) ~= 0 and 15 or 0
        else
          goto nextPixel
        end
        image:drawPixel(x, y, displayIndex(model.view, shade))
      end
      ::nextPixel::
    end
  end
  return image
end

-- Сравниваем видимые цвета и прозрачность, допуская равнозначные чёрные индексы палитры.
local function matchesPlane(sprite, layer, model, image)
  local expected = renderPlane(model)
  if expected.bytes == image.bytes then return true end
  local palette, transparent = sprite.palettes[1], sprite.transparentColor
  for y = 0, HEIGHT - 1 do
    for x = 0, WIDTH - 1 do
      local a, b = image:getPixel(x, y), expected:getPixel(x, y)
      if a ~= b then
        if not layer.isBackground and (a == transparent or b == transparent) then return false end
        if a >= #palette or b >= #palette or palette:getColor(a).rgbaPixel ~= palette:getColor(b).rgbaPixel then
          return false
        end
      end
    end
  end
  return true
end

-- Считаем сохранённые исключения для миграции старых масок, это не число ошибок видимого экрана.
local function exceptionCount(state)
  local cells, count = {}, 0
  for _, model in pairs(state.planes) do
    for position in pairs(model.overrides) do
      local index = attrOffset((position - 1) % WIDTH, (position - 1) // WIDTH)
      if not cells[index] then cells[index], count = true, count + 1 end
    end
  end
  return count
end

-- Передаём общие атрибуты всем слоям, включая скрытые и заблокированные.
local function shareAttributes(state)
  for _, model in pairs(state.planes) do
    for i = 6145, SCR_SIZE do model.screen[i] = state.common[i] end
  end
end

-- Собираем физический SCR из видимых слоёв, верхний непрозрачный пиксель побеждает.
local function composite(sprite, state)
  local result = blankPlane(state.common, state.view).screen
  for _, item in ipairs(imageLayers(sprite)) do
    local model = state.planes[item.layer.id]
    if item.visible and model then
      for i = 1, 6144 do
        local mask = model.mask[i]
        result[i] = (result[i] & (255 ~ mask)) | (model.screen[i] & mask)
      end
    end
  end
  return result
end

-- Проверяем итоговые видимые пиксели, скрытые и перекрытые части слоёв не создают ошибок SCR.
local function visibleAnalysis(sprite, state)
  local layers = imageLayers(sprite)
  local parts = {}
  for _, item in ipairs(layers) do parts[#parts + 1] = item.layer.id .. ":" .. tostring(item.visible) end
  local signature = table.concat(parts, "/")
  if state.diagnostics and state.diagnostics.signature == signature then return state.diagnostics end
  local result = { signature = signature, cells = {}, screen = composite(sprite, state) }

  for cy = 0, 23 do
    for cx = 0, 31 do
      local colors, counts, pixels = {}, {}, {}
      local count, bright, mixed = 0, nil, false

      -- Для каждой позиции берём только верхний видимый непрозрачный пиксель слоя ZX.
      for dy = 0, 7 do
        for dx = 0, 7 do
          local x, y = cx * 8 + dx, cy * 8 + dy
          local shade
          for i = #layers, 1, -1 do
            local item = layers[i]
            local model = state.planes[item.layer.id]
            if item.visible and model and covered(model, x, y) then
              shade = model.overrides[1 + y * WIDTH + x] or ZX.pixel(model.screen, x, y)
              break
            end
          end
          if shade ~= nil then
            pixels[#pixels + 1] = { x = x, y = y, shade = shade }
            local base = shade & 7
            if not counts[base] then count = count + 1; colors[#colors + 1] = base; counts[base] = 0 end
            counts[base] = counts[base] + 1
            if base ~= 0 then
              local value = shade >> 3
              if bright ~= nil and bright ~= value then mixed = true end
              if bright == nil then bright = value end
            end
          end
        end
      end

      local attrIndex = 6145 + cy * 32 + cx
      if count > 2 or mixed then
        result.cells[#result.cells + 1] = {
          x = cx, y = cy, centerX = cx * 8 + 4, centerY = cy * 8 + 4,
          extraColors = count > 2, mixedBrightness = mixed
        }
      elseif #pixels > 0 then
        -- Сохраняем существующую пару, если она уже отображает итоговые цвета без искажений.
        local attr = state.common[attrIndex]
        local ink, paper, oldBright = attr & 7, (attr >> 3) & 7, (attr >> 6) & 1
        local compatible = bright == nil or oldBright == bright
        for _, base in ipairs(colors) do
          if base ~= ink and base ~= paper then compatible = false end
        end

        -- При необходимости кодируем допустимый видимый результат собственной парой INK/PAPER.
        if not compatible then
          if not counts[paper] then
            paper = colors[1]
            for _, base in ipairs(colors) do if counts[base] > counts[paper] then paper = base end end
          end
          if ink == paper or not counts[ink] then
            local other
            for _, base in ipairs(colors) do if base ~= paper then other = base; break end end
            ink = other or ink
          end
          attr = (attr & 128) | ink | (paper << 3) | ((bright or oldBright) << 6)
        end
        result.screen[attrIndex] = attr

        -- Формируем экспорт по видимой картинке, даже если скрытые слои ещё содержат исключения.
        if ink ~= paper then
          for _, pixel in ipairs(pixels) do
            local offset, bit = bitmapOffset(pixel.x, pixel.y), 128 >> (pixel.x & 7)
            if (pixel.shade & 7) == ink then result.screen[offset] = result.screen[offset] | bit
            else result.screen[offset] = result.screen[offset] & (255 ~ bit) end
          end
        end
      end
    end
  end
  state.diagnostics = result
  return result
end

local function snapshot(sprite)
  local images = {}
  for _, item in ipairs(imageLayers(sprite)) do
    images[item.layer.id] = captureLayer(sprite, item.layer)
  end
  return images
end

-- Восстанавливаем маски слоёв и общие атрибуты из документа или старой версии скрипта.
local function readState(sprite, images)
  local common = sprite.properties(PROPERTY).scr
  if type(common) ~= "table" or #common ~= SCR_SIZE then return nil end
  local state = { common = common, planes = {}, view = paletteView(sprite) }
  local layers = imageLayers(sprite)
  local mismatched = false
  for _, item in ipairs(layers) do
    local layer = item.layer
    local stored = layer.properties(PROPERTY)
    local bits, mask = stored.bits, stored.mask
    local model = blankPlane(common, state.view)
    if type(bits) == "table" and #bits == 6144 and type(mask) == "table" and #mask == 6144 then
      for i = 1, 6144 do model.screen[i], model.mask[i] = bits[i], mask[i] end
      local exceptions = stored.exceptions
      if type(exceptions) == "table" then
        for i = 1, #exceptions, 2 do model.overrides[exceptions[i]] = exceptions[i + 1] end
      end
    elseif #layers == 1 and ZX.render(common, state.view).bytes == images[layer.id].bytes then
      for i = 1, 6144 do model.screen[i], model.mask[i] = common[i], 255 end
    else
      for pixel in images[layer.id]:pixels() do
        if pixel() ~= sprite.transparentColor then return nil end
      end
    end
    if not matchesPlane(sprite, layer, model, images[layer.id]) then mismatched = true end
    state.planes[layer.id] = model
  end
  -- Восстанавливаем полный рисунок из метаданных, если аварийная копия сохранила временный вид.
  if mismatched then
    if (sprite.properties(PROPERTY).version or 0) < 6 then return nil end
    local recovered = false
    for flags = 0, 6 do
      local channels = { ink = (flags & 1) ~= 0, paper = (flags & 2) ~= 0, bright = (flags & 4) ~= 0 }
      local matches = true
      for _, item in ipairs(layers) do
        local id = item.layer.id
        if renderChannels(state.planes[id], channels).bytes ~= images[id].bytes then matches = false; break end
      end
      if matches then recovered = true; break end
    end
    if not recovered then return nil end
    state.recoveredProjection = true
  end
  return state
end

-- Сначала восстанавливаем рисунок каждого слоя, не смешивая его исходные цвета с соседними слоями.
local function inferState(sprite, images, inkShade, paperShade)
  local layers = imageLayers(sprite)
  local view = paletteView(sprite)
  local shades = view.shades
  local default = {}
  for i = 1, 6144 do default[i] = 0 end
  for i = 6145, SCR_SIZE do
    default[i] = (inkShade & 7) | ((paperShade & 7) << 3) | ((inkShade & 8) << 3)
  end
  local state = { common = default, planes = {}, view = view }
  local ownAttributes = {}
  local invalid = {}
  local selected = app.activeLayer
  local selectedId

  for _, item in ipairs(layers) do
    local layer = item.layer
    local image = images[layer.id]
    local model = blankPlane(default, view)
    local attributes = {}
    ownAttributes[layer.id] = attributes
    state.planes[layer.id] = model
    if selected and layer.id == selected.id then selectedId = layer.id end
    for cy = 0, 23 do
      for cx = 0, 31 do
        local counts, colors, bright = {}, {}, nil
        local attrIndex = 6145 + cy * 32 + cx

        -- Определяем исходную пару только по пикселям этой клетки этого слоя.
        for dy = 0, 7 do
          for dx = 0, 7 do
            local index = image:getPixel(cx * 8 + dx, cy * 8 + dy)
            if layer.isBackground or index ~= sprite.transparentColor then
              local shade = shades[index]
              assert(shade ~= nil, "Есть неспектрумовский цвет, исходник не изменён.")
              local base = shade & 7
              if not counts[base] then counts[base] = 0; colors[#colors + 1] = base end
              counts[base] = counts[base] + 1
              if base ~= 0 then
                local value = shade >> 3
                if bright ~= nil and bright ~= value then invalid[attrIndex] = true end
                if bright == nil then bright = value end
              end
            end
          end
        end

        local ink, paper = inkShade & 7, paperShade & 7
        if #colors > 2 then invalid[attrIndex] = true end
        if #colors == 1 then
          local color = colors[1]
          if color == ink and ink ~= paper then ink = color else paper = color end
        elseif #colors >= 2 then
          if counts[ink] and ink ~= paper then
            -- Выбранный INK присутствует в исходнике, второй цвет остаётся PAPER.
            if not counts[paper] or paper == ink then
              paper = nil
              for _, color in ipairs(colors) do
                if color ~= ink and (paper == nil or counts[color] > counts[paper]) then paper = color end
              end
            end
          elseif counts[paper] and paper ~= ink then
            ink = nil
            for _, color in ipairs(colors) do
              if color ~= paper and (ink == nil or counts[color] > counts[ink]) then ink = color end
            end
          else
            -- Без совпадений с выбранной парой используем наиболее частый цвет как фон этого слоя.
            paper = colors[1]
            for _, color in ipairs(colors) do if counts[color] > counts[paper] then paper = color end end
            ink = nil
            for _, color in ipairs(colors) do
              if color ~= paper and (ink == nil or counts[color] > counts[ink]) then ink = color end
            end
          end
        end
        attributes[attrIndex] = ink | (paper << 3) | ((bright or (paperShade >> 3)) << 6)

        -- Запоминаем биты и прозрачность независимо от будущего общего атрибута.
        for dy = 0, 7 do
          for dx = 0, 7 do
            local x, y = cx * 8 + dx, cy * 8 + dy
            local index = image:getPixel(x, y)
            if layer.isBackground or index ~= sprite.transparentColor then
              local offset, bit = bitmapOffset(x, y), 128 >> (x & 7)
              -- Только исходный цвет INK задаёт бит рисунка, белый и зелёный не сливаются с контуром.
              if (shades[index] & 7) == ink then model.screen[offset] = model.screen[offset] | bit end
              model.mask[offset] = model.mask[offset] | bit
            end
          end
        end
      end
    end
  end

  -- Исходные общие атрибуты берём с выбранного слоя, остальные сохраняют свои биты.
  selectedId = selectedId or layers[1].layer.id
  for i = 6145, SCR_SIZE do state.common[i] = ownAttributes[selectedId][i] end
  shareAttributes(state)

  -- Сохраняем вид исходника там, где исходные пары разных слоёв ещё не приведены к общей паре.
  for _, item in ipairs(layers) do
    local model, image = state.planes[item.layer.id], images[item.layer.id]
    for y = 0, HEIGHT - 1 do
      for x = 0, WIDTH - 1 do
        if covered(model, x, y) then
          local shade = shades[image:getPixel(x, y)]
          local expected = ZX.pixel(model.screen, x, y)
          if (shade & 7) ~= (expected & 7) or ((shade & 7) ~= 0 and (shade & 8) ~= (expected & 8)) then
            invalid[attrOffset(x, y)] = true
          end
        end
      end
    end
  end
  for _, item in ipairs(layers) do
    local model, image = state.planes[item.layer.id], images[item.layer.id]
    for y = 0, HEIGHT - 1 do
      for x = 0, WIDTH - 1 do
        if covered(model, x, y) and invalid[attrOffset(x, y)] then
          model.overrides[1 + y * WIDTH + x] = shades[image:getPixel(x, y)]
        end
      end
    end
  end
  return state
end

-- Исправляем старую ошибку масок только в ещё не обработанных клетках, сохраняя готовый рисунок.
local function restoreState(sprite, images, inkShade, paperShade)
  local saved = readState(sprite, images)
  if not saved or (sprite.properties(PROPERTY).version or 0) >= 5 or exceptionCount(saved) == 0 then
    return saved
  end
  local cells = {}
  for _, model in pairs(saved.planes) do
    for position in pairs(model.overrides) do
      cells[attrOffset((position - 1) % WIDTH, (position - 1) // WIDTH)] = true
    end
  end
  local repaired = inferState(sprite, images, inkShade, paperShade)
  for cy = 0, 23 do
    for cx = 0, 31 do
      local attrIndex = 6145 + cy * 32 + cx
      if not cells[attrIndex] then
        repaired.common[attrIndex] = saved.common[attrIndex]
        for id, model in pairs(repaired.planes) do
          local prior = saved.planes[id]
          if prior then
            for dy = 0, 7 do
              local offset = bitmapOffset(cx * 8, cy * 8 + dy)
              model.screen[offset], model.mask[offset] = prior.screen[offset], prior.mask[offset]
              for dx = 0, 7 do model.overrides[1 + (cy * 8 + dy) * WIDTH + cx * 8 + dx] = nil end
            end
          end
        end
      end
    end
  end
  shareAttributes(repaired)
  return repaired
end

local function cloneState(state)
  local copy = { common = ZX.decode(ZX.encode(state.common)), planes = {}, view = state.view }
  for id, model in pairs(state.planes) do
    local plane = blankPlane(copy.common, copy.view)
    for i = 1, 6144 do plane.screen[i], plane.mask[i] = model.screen[i], model.mask[i] end
    for position, shade in pairs(model.overrides) do plane.overrides[position] = shade end
    copy.planes[id] = plane
  end
  return copy
end

-- Выбираем исправления по видимым пикселям, соседей используем только для разрешения равенства.
local function autoCorrectState(sprite, state)
  local layers, cells = imageLayers(sprite), {}
  local errors = visibleAnalysis(sprite, state).cells
  for cy = 0, 23 do for cx = 0, 31 do
    local cell = { counts = {}, bright = { [0] = 0, [1] = 0 }, colors = {} }
    cells[cy * 32 + cx] = cell
    for dy = 0, 7 do for dx = 0, 7 do
      local x, y = cx * 8 + dx, cy * 8 + dy
      for i = #layers, 1, -1 do
        local item = layers[i]
        local plane = state.planes[item.layer.id]
        if item.visible and plane and covered(plane, x, y) then
          local shade = plane.overrides[1 + y * WIDTH + x] or ZX.pixel(plane.screen, x, y)
          local base = shade & 7
          if not cell.counts[base] then cell.colors[#cell.colors + 1] = base; cell.counts[base] = 0 end
          cell.counts[base] = cell.counts[base] + 1
          if base ~= 0 then cell.bright[shade >> 3] = cell.bright[shade >> 3] + 1 end
          break
        end
      end
    end end
    cell.valid = #cell.colors <= 2 and (cell.bright[0] == 0 or cell.bright[1] == 0)
  end end
  local candidate, fixed = cloneState(state), 0

  for _, errorCell in ipairs(errors) do
    local cx, cy = errorCell.x, errorCell.y
    local cell = cells[cy * 32 + cx]
    local neighbors, neighborBright = {}, { [0] = 0, [1] = 0 }
    -- Соседние допустимые клетки дают подсказку, ошибки соседей не распространяются дальше.
    for _, step in ipairs { {-1,0}, {1,0}, {0,-1}, {0,1} } do
      local nx, ny = cx + step[1], cy + step[2]
      if nx >= 0 and nx < 32 and ny >= 0 and ny < 24 then
        local neighbor = cells[ny * 32 + nx]
        if neighbor.valid then
          for base, count in pairs(neighbor.counts) do neighbors[base] = (neighbors[base] or 0) + count end
          for bright = 0, 1 do neighborBright[bright] = neighborBright[bright] + neighbor.bright[bright] end
        end
      end
    end
    local ranked = {}
    for _, base in ipairs(cell.colors) do ranked[#ranked + 1] = base end
    table.sort(ranked, function(a, b)
      if cell.counts[a] ~= cell.counts[b] then return cell.counts[a] > cell.counts[b] end
      if (neighbors[a] or 0) ~= (neighbors[b] or 0) then return (neighbors[a] or 0) > (neighbors[b] or 0) end
      return a < b
    end)
    -- Равенство на границе выбранной пары без поддержки соседей оставляем пользователю.
    if #ranked > 2 and cell.counts[ranked[2]] == cell.counts[ranked[3]] and
      (neighbors[ranked[2]] or 0) == (neighbors[ranked[3]] or 0) then goto nextCell end
    local attrIndex = 6145 + cy * 32 + cx
    local attr = state.common[attrIndex]
    local bright
    if cell.bright[0] > cell.bright[1] then bright = 0
    elseif cell.bright[1] > cell.bright[0] then bright = 1
    elseif cell.bright[0] == 0 then bright = (attr >> 6) & 1
    elseif neighborBright[0] > neighborBright[1] then bright = 0
    elseif neighborBright[1] > neighborBright[0] then bright = 1
    else goto nextCell end

    local selected = { [ranked[1]] = true }
    if ranked[2] then selected[ranked[2]] = true end
    local ink, paper = attr & 7, (attr >> 3) & 7
    -- Сохраняем роли существующих цветов, когда они входят в выбранную пару.
    if #ranked == 1 then
      if ink ~= ranked[1] and paper ~= ranked[1] then paper = ranked[1] end
    elseif selected[ink] and ink ~= paper then
      paper = ranked[1] == ink and ranked[2] or ranked[1]
    elseif selected[paper] then
      ink = ranked[1] == paper and ranked[2] or ranked[1]
    else paper, ink = ranked[1], ranked[2] end

    local mapping = { [ink] = ink, [paper] = paper }
    local function distance(a, b)
      local xor = a ~ b
      return (xor & 1) + ((xor >> 1) & 1) + ((xor >> 2) & 1)
    end
    -- В спектрумовском RGB расстояние равно числу отличающихся цветовых составляющих.
    for base = 0, 7 do
      if mapping[base] == nil then
        local toInk, toPaper = distance(base, ink), distance(base, paper)
        if toInk < toPaper then mapping[base] = ink
        elseif toPaper < toInk then mapping[base] = paper
        elseif (neighbors[ink] or 0) > (neighbors[paper] or 0) then mapping[base] = ink
        elseif (neighbors[paper] or 0) > (neighbors[ink] or 0) then mapping[base] = paper end
      end
    end
    for _, base in ipairs(cell.colors) do if mapping[base] == nil then goto nextCell end end
    local newAttr = (attr & 128) | ink | (paper << 3) | (bright << 6)
    -- Исправляем биты и исключения слоёв внутри клетки, маски прозрачности сохраняем.
    for id, plane in pairs(candidate.planes) do
      local original = state.planes[id]
      for dy = 0, 7 do for dx = 0, 7 do
        local x, y = cx * 8 + dx, cy * 8 + dy
        if covered(original, x, y) then
          local position = 1 + y * WIDTH + x
          local shade = original.overrides[position] or ZX.pixel(original.screen, x, y)
          local base = mapping[shade & 7]
          if base ~= nil then
            local offset, bit = bitmapOffset(x, y), 128 >> (x & 7)
            if ink ~= paper then
              if base == ink then plane.screen[offset] = plane.screen[offset] | bit
              else plane.screen[offset] = plane.screen[offset] & (255 ~ bit) end
            end
            plane.overrides[position] = nil
          else
            -- Неоднозначный скрытый цвет не влияет на исправленный видимый экран и сохраняется.
            plane.overrides[position] = shade
          end
        end
      end end
      plane.screen[attrIndex] = newAttr
    end
    candidate.common[attrIndex] = newAttr
    fixed = fixed + 1
    ::nextCell::
  end
  return candidate, fixed, #errors
end

-- Сохраняем все перекрашенные слои и их логические маски одной транзакцией.
local function writeState(sprite, state, preserveImages)
  shareAttributes(state)
  for _, item in ipairs(imageLayers(sprite)) do
    local layer, model = item.layer, state.planes[item.layer.id]
    if model then
      if not preserveImages then
        local cel = layer:cel(1)
        local image = renderPlane(model)
        if cel then
          cel.image = image
          cel.position = Point(0, 0)
        else
          local hasPixels = false
          for _, byte in ipairs(model.mask) do if byte ~= 0 then hasPixels = true; break end end
          if hasPixels then sprite:newCel(layer, 1, image, Point(0, 0)) end
        end
      end
      local bits = {}
      for i = 1, 6144 do bits[i] = model.screen[i] end
      layer.properties(PROPERTY).bits = bits
      layer.properties(PROPERTY).mask = model.mask
      -- Сохраняем исключения рядом с маской для точного восстановления через Undo и .aseprite.
      local positions, exceptions = {}, {}
      for position in pairs(model.overrides) do positions[#positions + 1] = position end
      table.sort(positions)
      for _, position in ipairs(positions) do
        exceptions[#exceptions + 1] = position
        exceptions[#exceptions + 1] = model.overrides[position]
      end
      layer.properties(PROPERTY).exceptions = exceptions
    end
  end
  sprite.properties(PROPERTY).scr = composite(sprite, state)
  sprite.properties(PROPERTY).version = 6
end

-- Показываем сетку знакомест, не включая привязку кисти к сетке.
local function showGrid(sprite)
  sprite.gridBounds = Rectangle(0, 0, 8, 8)
  app.preferences.document(sprite).show.grid = true
end

function ZX.attach(sprite, status)
  status = status or function() end
  local self = { enabled = false, busy = false, pending = {}, sprite = sprite, closed = false }
  local listeners = {}
  local state, previous
  local projection = {}
  local commandDepth = 0
  local changingColors = false
  local normalColors
  self.channels = { ink = true, paper = true, bright = true, flash = false }
  local function tell(message)
    if not self.closed then status(message, self.enabled) end
  end

  -- Проверка isValid не обращается к полям уже удалённого документа.
  function self.documentAlive()
    if self.closed then return false end
    local ok, valid = pcall(function() return sprite.isValid end)
    return ok and valid == true
  end

  -- Возвращаем исходные буферы без новых команд истории, включая буфер до нативного мазка.
  local function restoreProjection()
    for _, entry in pairs(projection) do
      pcall(function() entry.buffer.bytes = entry.bytes end)
      pcall(function()
        local cel = entry.layer:cel(1)
        if not cel then return end
        local image = cel.image:clone()
        image:clear(sprite.transparentColor)
        image:drawImage(entry.original, Point(entry.position.x - cel.position.x, entry.position.y - cel.position.y))
        cel.image.bytes = image.bytes
      end)
    end
    projection = {}
  end

  -- Перерисовываем только временные байты существующих cels, геометрия и история неизменны.
  function self.refreshView()
    if not self.documentAlive() or not self.enabled or self.busy or commandDepth > 0 or
      app.activeSprite ~= sprite or #self.pending > 0 or not self.viewDirty then return end
    restoreProjection()
    local prepared = {}
    local full = self.channels.ink and self.channels.paper and self.channels.bright
    if not full then
      -- Сначала готовим все изображения, чтобы ошибка палитры не оставила частичный вид.
      for _, item in ipairs(imageLayers(sprite)) do
        local layer = item.layer
        local cel, model = layer:cel(1), state.planes[layer.id]
        if cel and model then
          local image = cel.image:clone()
          image:clear(sprite.transparentColor)
          image:drawImage(renderChannels(model, self.channels), Point(-cel.position.x, -cel.position.y))
          prepared[#prepared + 1] = { layer = layer, buffer = cel.image, bytes = cel.image.bytes,
            original = cel.image:clone(), position = Point(cel.position.x, cel.position.y), display = image.bytes }
        end
      end
      for _, entry in ipairs(prepared) do
        projection[entry.layer.id] = entry
        entry.buffer.bytes = entry.display
      end
    end
    previous = snapshot(sprite)
    self.viewDirty = false
    app.refresh()
  end

  local function suspendView()
    restoreProjection()
    if self.documentAlive() then previous = snapshot(sprite) end
    self.viewDirty = true
  end

  local function monochrome()
    return not self.channels.paper and (self.channels.ink or self.channels.bright)
  end

  -- Ограничиваем рисующие цвета монохромным режимом, не трогая палитру и цвета полного вида.
  local function drawingColors()
    if changingColors then return end
    changingColors = true
    if monochrome() then
      normalColors = normalColors or { fg = app.fgColor, bg = app.bgColor }
      local fg = displayIndex(state.view, self.channels.ink and 0 or 15)
      local bg = displayIndex(state.view, self.channels.ink and 7 or 0)
      if app.fgColor.index ~= fg then app.fgColor = Color { index = fg } end
      if app.bgColor.index ~= bg then app.bgColor = Color { index = bg } end
    elseif normalColors then
      app.fgColor, app.bgColor = normalColors.fg, normalColors.bg
      normalColors = nil
    end
    changingColors = false
  end
  local function activeMessage()
    local count = state and #visibleAnalysis(sprite, state).cells or 0
    return count > 0 and ("ZX ON: " .. count .. " invalid cells") or "ZX ON"
  end
  local function shadeOf(color)
    local index = color.index
    local view = state and state.view or paletteView(sprite)
    return view.shades[index] or nearest(color)
  end

  -- Читаем штатные цвета, не заменяя выбранные индексы или палитру документа.
  function self.syncColors()
    if changingColors or not self.documentAlive() or not self.enabled or app.activeSprite ~= sprite then return end
    drawingColors()
    self.colors = { ink = shadeOf(app.fgColor), paper = shadeOf(app.bgColor),
      fgIndex = app.fgColor.index, bgIndex = app.bgColor.index }
  end

  local function turnOff(message)
    self.pendingPicks = nil
    restoreProjection()
    changingColors = true
    if normalColors then app.fgColor, app.bgColor = normalColors.fg, normalColors.bg; normalColors = nil end
    changingColors = false
    self.enabled, self.pending = false, {}
    tell(message or "ZX OFF")
  end

  -- Выполняем коррекцию после завершения change, сохраняя одно Undo на мазок.
  function self.flush()
    if not self.documentAlive() then self.pending = {}; return end
    if self.busy or #self.pending == 0 then return end
    assert(app.activeSprite == sprite, "Вернитесь к документу ZX.")
    validate(sprite)
    local operations = self.pending
    self.pending, self.busy = {}, true
    local ok, err = pcall(function()
      for _ = 1, #operations do app.undo() end
      restoreProjection()
      for _, operation in ipairs(operations) do
        app.transaction("ZX INK / PAPER", function() writeState(sprite, operation) end)
      end
      state = operations[#operations]
      previous = snapshot(sprite)
    end)
    self.busy = false
    if not ok then turnOff("ZX ERROR"); error(err) end
    self.syncColors()
    self.viewDirty = true
    self.refreshView()
    app.refresh()
    tell(activeMessage())
  end

  -- Инициализируем общий экран с сохранением структуры слоёв и скрытых битов.
  function self.enable()
    assert(self.documentAlive(), "Документ закрыт. Откройте панель ZX заново для нужного документа.")
    validate(sprite)
    assert(app.activeSprite == sprite, "Выберите документ этой панели.")
    suspendView()
    local images = snapshot(sprite)
    local fg, bg = shadeOf(app.fgColor), shadeOf(app.bgColor)
    local candidate = restoreState(sprite, images, fg, bg) or inferState(sprite, images, fg, bg)
    self.busy = true
    local ok, err = pcall(function()
      app.transaction("ZX enable", function()
        writeState(sprite, candidate, not candidate.recoveredProjection)
        showGrid(sprite)
      end)
    end)
    self.busy = false
    if not ok then error(err) end
    state, previous = candidate, snapshot(sprite)
    self.enabled, self.pending = true, {}
    self.syncColors()
    self.viewDirty = true
    self.refreshView()
    app.refresh()
    local count = #visibleAnalysis(sprite, state).cells
    self.lastWarning = count > 0 and table.concat({
      "Нарушены ограничения Spectrum.",
      "- Клеток с ошибками: " .. count,
      "- В них больше двух цветов или разная яркость.",
      "- ZX включён, картинка пока не изменена.",
      "- Нарисуйте кистью в такой клетке 8×8.",
      "- Отпустите кнопку мыши, чтобы обновить цвета.",
      "- INK — основной цвет, PAPER — фоновый.",
      "- Яркость общая для INK и PAPER.",
      "- Исправьте все клетки, чтобы сохранить SCR."
    }, "\n") or nil
    tell(activeMessage())
  end

  function self.disable() self.flush(); turnOff() end

  -- Переключение каналов не меняет модель рисунка, атрибуты или историю Undo.
  function self.setChannels(channels)
    assert(self.documentAlive(), "Документ закрыт.")
    self.flush()
    suspendView()
    self.channels = { ink = channels.ink == true, paper = channels.paper == true,
      bright = channels.bright == true, flash = false }
    if self.enabled then self.syncColors(); self.refreshView(); tell(activeMessage()) end
  end

  -- Читаем настоящий верхний пиксель, исключения ошибочной клетки важнее старого атрибута.
  local function sourceShadeAt(x, y)
    if not state then return nil end
    local layers = imageLayers(sprite)
    for i = #layers, 1, -1 do
      local item = layers[i]
      local plane = state.planes[item.layer.id]
      if item.visible and plane and covered(plane, x, y) then
        return plane.overrides[1 + y * WIDTH + x] or ZX.pixel(plane.screen, x, y)
      end
    end
  end

  -- Пипетка сохраняет цвет выбранного пикселя только для нажатой кнопки мыши.
  function self.pickPixel(x, y, target)
    assert(self.documentAlive() and self.enabled, "Сначала включите ZX.")
    assert(x >= 0 and x < WIDTH and y >= 0 and y < HEIGHT, "Выберите точку внутри холста.")
    assert(target == "ink" or target == "paper", "Укажите основной или фоновый цвет.")
    self.flush()
    local shade = sourceShadeAt(x, y)
    if shade == nil then return nil end
    local color = Color { index = displayIndex(state.view, shade) }
    changingColors = true
    if monochrome() then
      if target == "ink" then normalColors.fg = color else normalColors.bg = color end
    else
      if target == "ink" then app.fgColor = color else app.bgColor = color end
    end
    changingColors = false
    self.syncColors()
    tell(string.format("Пипетка %s: цвет %d, BRIGHT %d", target:upper(), shade & 7, shade >> 3))
    return shade
  end

  -- Два быстрых выбора разных кнопок не перезаписывают друг друга до тика таймера.
  function self.processNativePicks()
    local picks = self.pendingPicks or {}
    self.pendingPicks = nil
    if not self.enabled or not self.documentAlive() then return end
    for _, target in ipairs { "ink", "paper" } do
      local point = picks[target]
      if point then self.pickPixel(point.x, point.y, target) end
    end
  end

  local function queueNativePick(target)
    local editor = app.editor
    if not editor or editor.sprite ~= sprite then return false end
    local point = editor.spritePos
    if point.x < 0 or point.x >= WIDTH or point.y < 0 or point.y >= HEIGHT then return false end
    if sourceShadeAt(point.x, point.y) == nil then return false end
    self.pendingPicks = self.pendingPicks or {}
    self.pendingPicks[target] = { x = point.x, y = point.y }
    return true
  end

  -- Чтение списка не запускает flush, его также использует панель из обработчика change.
  function self.invalidCells()
    local result = {}
    if self.documentAlive() and state then
      for _, cell in ipairs(visibleAnalysis(sprite, state).cells) do
        result[#result + 1] = { x = cell.x, y = cell.y, centerX = cell.centerX, centerY = cell.centerY }
      end
    end
    return result
  end

  function self.refreshDiagnostics()
    if self.documentAlive() and self.enabled and state then
      local diagnostics = visibleAnalysis(sprite, state)
      if self.lastDiagnostics ~= diagnostics then
        self.lastDiagnostics = diagnostics
        tell(activeMessage())
      end
    end
  end

  -- Все выбранные автоматические исправления входят в один шаг штатной истории.
  function self.autoCorrect()
    assert(self.documentAlive() and self.enabled, "Сначала включите ZX.")
    assert(app.activeSprite == sprite, "Выберите документ панели ZX.")
    self.flush()
    suspendView()
    local candidate, fixed, before = autoCorrectState(sprite, state)
    if fixed > 0 then
      -- Проверяем возможность отрисовать результат до изменения документа.
      for _, plane in pairs(candidate.planes) do renderPlane(plane) end
      self.busy = true
      local ok, err = pcall(function()
        app.transaction("ZX автоисправление", function() writeState(sprite, candidate) end)
      end)
      self.busy = false
      if not ok then self.refreshView(); error(err) end
      state, previous = candidate, snapshot(sprite)
    end
    self.viewDirty = true
    self.refreshView()
    local remaining = #visibleAnalysis(sprite, state).cells
    tell(string.format("Авто: исправлено %d, осталось %d", fixed, remaining))
    return { before = before, fixed = fixed, remaining = remaining }
  end

  -- Центрируем активный холст на выбранном знакоместе без изменения масштаба и рисунка.
  function self.focusCell(x, y)
    assert(self.documentAlive(), "Документ закрыт.")
    assert(x >= 0 and x < 32 and y >= 0 and y < 24, "Клетка находится вне экрана 32×24.")
    assert(app.activeSprite == sprite, "Выберите документ этой панели ZX.")
    self.flush()
    local editor = app.editor
    assert(editor and editor.sprite == sprite, "Нет активного холста этого документа.")
    editor.scroll = { x = x * 8 + 4, y = y * 8 + 4 }
    app.refresh()
  end

  -- Распознаём действие кисти только на выбранном слое, остальные маски не меняем.
  local function changed(ev)
    if not self.documentAlive() or self.busy or not self.enabled then return end
    local ok, err = pcall(function()
      validate(sprite)
      local images = snapshot(sprite)
      if ev and ev.fromUndo then
        self.pending = {}
        local restored = restoreState(sprite, images, shadeOf(app.fgColor), shadeOf(app.bgColor))
        if not restored then turnOff("ZX initialization undone"); return end
        state, previous = restored, images
        self.viewDirty = true
        tell(activeMessage())
        return
      end
      local nextState, modified = cloneState(state), false
      local retained = {}
      local resolved = {}
      self.syncColors()
      local colors = self.colors
      local target = app.activeLayer
      for _, item in ipairs(imageLayers(sprite)) do
        local id = item.layer.id
        retained[id] = true
        local image, before = images[id], previous[id]
        local model = nextState.planes[id] or blankPlane(nextState.common, nextState.view)
        nextState.planes[id] = model
        -- Остальные слои получают атрибуты, но не интерпретируются как действие кисти.
        if not target or target.id ~= id then goto nextLayer end
        for y = 0, HEIGHT - 1 do
          for x = 0, WIDTH - 1 do
            local value = image:getPixel(x, y)
            local old = before and before:getPixel(x, y) or sprite.transparentColor
            if value ~= old then
              modified = true
              local eraser = app.tool and app.tool.id == "eraser"
              local channels = self.channels
              local paperStroke = value == colors.bgIndex and colors.bgIndex ~= colors.fgIndex
              -- В отдельном канале изменяем только его данные, остальные составляющие сохраняем.
              if not (channels.ink and channels.paper) then
                local attrIndex = attrOffset(x, y)
                local attr = nextState.common[attrIndex]
                if channels.ink then
                  local offset, bit = bitmapOffset(x, y), 128 >> (x & 7)
                  if value == sprite.transparentColor and eraser then
                    model.mask[offset] = model.mask[offset] & (255 ~ bit)
                  else
                    model.mask[offset] = model.mask[offset] | bit
                    if paperStroke then model.screen[offset] = model.screen[offset] & (255 ~ bit)
                    else model.screen[offset] = model.screen[offset] | bit end
                  end
                  model.overrides[1 + y * WIDTH + x] = nil
                elseif channels.paper then
                  local shade = paperStroke and colors.paper or colors.ink
                  local oldPaper = (attr >> 3) & 7
                  attr = (attr & 199) | ((shade & 7) << 3)
                  if channels.bright then attr = (attr & 191) | ((shade & 8) << 3) end
                  local cellX, cellY = (x // 8) * 8, (y // 8) * 8
                  for _, other in pairs(nextState.planes) do
                    for dy = 0, 7 do for dx = 0, 7 do
                      local position = 1 + (cellY + dy) * WIDTH + cellX + dx
                      local extra = other.overrides[position]
                      if extra ~= nil and (extra & 7) == oldPaper then other.overrides[position] = nil end
                    end end
                  end
                elseif channels.bright then
                  attr = (attr & 191) | (paperStroke and 0 or 64)
                  local cellX, cellY = (x // 8) * 8, (y // 8) * 8
                  for _, other in pairs(nextState.planes) do
                    for dy = 0, 7 do for dx = 0, 7 do
                      local position = 1 + (cellY + dy) * WIDTH + cellX + dx
                      local extra = other.overrides[position]
                      if extra ~= nil then other.overrides[position] = (extra & 7) | ((attr & 64) >> 3) end
                    end end
                  end
                end
                nextState.common[attrIndex] = attr
                for _, other in pairs(nextState.planes) do other.screen[attrIndex] = attr end
                goto continue
              end
              if value == sprite.transparentColor and
                (eraser or (value ~= colors.fgIndex and value ~= colors.bgIndex)) then
                -- Ластик освобождает пиксель верхнего слоя, сохраняя нижний рисунок.
                local offset, bit = bitmapOffset(x, y), 128 >> (x & 7)
                model.mask[offset] = model.mask[offset] & (255 ~ bit)
                model.overrides[1 + y * WIDTH + x] = nil
                goto continue
              end
              -- Основной цвет ставит INK, фоновый цвет сбрасывает пиксель в PAPER.
              -- Одинаковая пара даёт одинаковый BRIGHT для обеих кнопок.
              -- Яркость чёрного не должна осветлять выбранный цветной PAPER.
              local bright = colors.ink
              if (colors.ink & 7) == 0 and (colors.paper & 7) ~= 0 then bright = colors.paper end
              local pair = (nextState.common[attrOffset(x, y)] & 128) |
                (colors.ink & 7) | ((colors.paper & 7) << 3) | ((bright & 8) << 3)
              if not channels.bright then
                pair = (pair & 191) | (nextState.common[attrOffset(x, y)] & 64)
              end
              local attrIndex = attrOffset(x, y)
              -- Восстанавливаем принадлежность исходных цветов новой паре до изменения бита кистью.
              if not resolved[attrIndex] then
                local cellX, cellY = (x // 8) * 8, (y // 8) * 8
                for _, other in pairs(nextState.planes) do
                  for dy = 0, 7 do
                    for dx = 0, 7 do
                      local px, py = cellX + dx, cellY + dy
                      local position = 1 + py * WIDTH + px
                      local shade = other.overrides[position]
                      -- Цвета вне выбранной пары сохраняем до явного рисования по этим пикселям.
                      if shade ~= nil then
                        local base = shade & 7
                        if base == (colors.ink & 7) or base == (colors.paper & 7) then
                          local offset, bit = bitmapOffset(px, py), 128 >> (px & 7)
                          if (colors.ink & 7) ~= (colors.paper & 7) then
                            if base == (colors.ink & 7) then
                              other.screen[offset] = other.screen[offset] | bit
                            else
                              other.screen[offset] = other.screen[offset] & (255 ~ bit)
                            end
                          end
                          other.overrides[position] = nil
                        end
                      end
                    end
                  end
                end
                resolved[attrIndex] = true
              end
              -- Меняем только нарисованный пиксель, включая исходный цвет вне пары.
              ZX.paint(model.screen, x, y, not paperStroke, paperStroke and colors.paper or colors.ink)
              local offset, bit = bitmapOffset(x, y), 128 >> (x & 7)
              model.mask[offset] = model.mask[offset] | bit
              model.overrides[1 + y * WIDTH + x] = nil
              nextState.common[attrIndex] = pair
              -- Следующий пиксель мазка должен видеть уже назначенные общие атрибуты.
              for _, other in pairs(nextState.planes) do
                other.screen[attrIndex] = nextState.common[attrIndex]
              end
            end
            ::continue::
          end
        end
        ::nextLayer::
      end
      for id in pairs(nextState.planes) do if not retained[id] then nextState.planes[id] = nil end end
      if modified then self.pending[#self.pending + 1] = nextState end
      state, previous = nextState, images
      tell(modified and "ZX applying..." or activeMessage())
    end)
    if not ok then turnOff("ZX OFF"); self.lastError = tostring(err) end
  end

  listeners[#listeners + 1] = { sprite.events, sprite.events:on("change", changed) }
  for _, event in ipairs { "layeropacity", "layervisibility", "layerblendmode" } do
    listeners[#listeners + 1] = { sprite.events, sprite.events:on(event, function()
      if not self.busy and self.enabled and self.documentAlive() then suspendView() end
    end) }
  end
  for _, event in ipairs { "fgcolorchange", "bgcolorchange" } do
    local target = event == "fgcolorchange" and "ink" or "paper"
    listeners[#listeners + 1] = { app.events, app.events:on(event, function()
      if changingColors or not self.enabled or not self.documentAlive() then return end
      if app.tool and app.tool.id == "eyedropper" and queueNativePick(target) then return end
      self.syncColors()
    end) }
  end
  -- До нативных команд возвращаем полное изображение, в том числе перед Save и Undo.
  listeners[#listeners + 1] = { app.events, app.events:on("beforecommand", function(ev)
    if self.busy or not self.documentAlive() or not self.enabled then return end
    -- Командный вызов пипетки обрабатываем и при совпадении цвета с уже выбранным.
    if ev and ev.name == "Eyedropper" and ev.params and ev.stopPropagation then
      local target = ev.params.target
      if (target == "foreground" or target == "background") and
        queueNativePick(target == "background" and "paper" or "ink") then
        ev.stopPropagation()
        return
      end
    end
    if #self.pending > 0 then self.flush() end
    suspendView()
    commandDepth = commandDepth + 1
  end) }
  listeners[#listeners + 1] = { app.events, app.events:on("aftercommand", function()
    if self.busy then return end
    commandDepth = math.max(0, commandDepth - 1)
    self.viewDirty = true
  end) }
  listeners[#listeners + 1] = { app.events, app.events:on("beforesitechange", function()
    if self.busy or not self.documentAlive() or not self.enabled then return end
    if #self.pending > 0 then self.flush() end
    suspendView()
  end) }
  listeners[#listeners + 1] = { app.events, app.events:on("sitechange", function()
    if not self.busy and self.enabled and app.activeSprite ~= sprite then turnOff() end
  end) }

  -- Экспортируем видимый результат, учитывая порядок и видимость слоёв.
  function self.bytes()
    assert(self.documentAlive(), "Документ закрыт.")
    self.flush()
    assert(state, "Сначала включите ZX.")
    local analysis = visibleAnalysis(sprite, state)
    local count = #analysis.cells
    assert(count == 0, "Нельзя сохранить SCR.\n" ..
      "Осталось клеток с ошибками: " .. count .. ".\n" ..
      "Откройте «Список ошибок» в панели ZX.\n" ..
      "Выберите клетку и исправьте её цвета.\n" ..
      "После исправления всех клеток сохраните SCR.")
    suspendView()
    for _, item in ipairs(imageLayers(sprite)) do
      local model = state.planes[item.layer.id]
      assert(model and matchesPlane(sprite, item.layer, model, captureLayer(sprite, item.layer)),
        "Слой изменён вне ZX. Снова включите режим перед экспортом.")
    end
    local bytes = ZX.encode(analysis.screen)
    self.refreshView()
    return bytes
  end

  -- Импортируем пиксели в выбранный слой, атрибуты применяем ко всему документу.
  function self.import(bytes)
    assert(self.documentAlive(), "Документ закрыт.")
    local imported = ZX.decode(bytes)
    validate(sprite)
    assert(app.activeSprite == sprite, "Выберите документ этой панели.")
    local target = app.activeLayer
    assert(target and target.isImage and not target.isGroup, "Выберите обычный растровый слой.")
    local eligible = false
    for _, item in ipairs(imageLayers(sprite)) do
      if item.layer.id == target.id then eligible = true; break end
    end
    assert(eligible, "Подложка исключена из ZX. Для импорта выберите слой с непрозрачностью 100%.")
    self.flush()
    suspendView()
    local fg, bg = shadeOf(app.fgColor), shadeOf(app.bgColor)
    local images = snapshot(sprite)
    local candidate = restoreState(sprite, images, fg, bg) or inferState(sprite, images, fg, bg)
    candidate.common = imported
    local plane = blankPlane(imported, candidate.view)
    for i = 1, 6144 do plane.screen[i], plane.mask[i] = imported[i], 255 end
    candidate.planes[target.id] = plane
    for _, model in pairs(candidate.planes) do model.overrides = {} end
    shareAttributes(candidate)
    self.busy = true
    local ok, err = pcall(function()
      app.transaction("ZX import SCR", function()
        writeState(sprite, candidate)
        showGrid(sprite)
      end)
    end)
    self.busy = false
    if not ok then error(err) end
    state, previous = candidate, snapshot(sprite)
    self.enabled = true
    self.syncColors()
    self.viewDirty = true
    self.refreshView()
    app.refresh()
    tell("ZX ON")
  end

  function self.close()
    if self.closed then return end
    -- Завершаем только уже начатую обработку живого активного документа.
    if self.documentAlive() and app.activeSprite == sprite and #self.pending > 0 then
      local ok, err = pcall(self.flush)
      if not ok then self.cleanupError = tostring(err) end
    end
    restoreProjection()
    if normalColors then
      changingColors = true
      app.fgColor, app.bgColor = normalColors.fg, normalColors.bg
      changingColors = false
      normalColors = nil
    end
    -- Отмечаем закрытие до снятия подписок, чтобы callbacks не обновляли закрываемую панель.
    self.closed, self.enabled, self.busy, self.pending = true, false, false, {}
    for _, item in ipairs(listeners) do
      local ok, err = pcall(function() item[1]:off(item[2]) end)
      if not ok and not self.cleanupError then self.cleanupError = tostring(err) end
    end
    listeners, state, previous, self.lastDiagnostics = {}, nil, nil, nil
    self.pendingPicks = nil
    self.lastWarning, self.lastError = nil, nil
  end
  return self
end

-- Выводим понятный текст без служебного пути и разбиваем длинные сообщения на строки.
local function showError(err)
  local message = tostring(err)
  local debugFile, debugLine = message:match("^(.-):(%d+):%s*")
  while true do
    local cleaned, removed = message:gsub("^.-:%d+:%s*", "", 1)
    message = cleaned
    if removed == 0 then break end
  end
  local lines = {}
  for paragraph in message:gmatch("[^\r\n]+") do
    local line = ""
    for word in paragraph:gmatch("%S+") do
      if line ~= "" and (utf8.len(line .. " " .. word) or #line + #word + 1) > 54 then
        lines[#lines + 1], line = line, ""
      end
      while (utf8.len(word) or #word) > 54 do
        local nextByte = utf8.offset(word, 55) or 55
        lines[#lines + 1] = word:sub(1, nextByte - 1)
        word = word:sub(nextByte)
      end
      line = line == "" and word or (line .. " " .. word)
    end
    if line ~= "" then lines[#lines + 1] = line end
  end
  if debugFile then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Скрипт: " .. debugFile:gsub("^.*[/\\]", "")
    lines[#lines + 1] = "Строка: " .. debugLine
  end
  app.alert { title = "ZX Spectrum", text = lines }
end

-- В пакетном режиме предоставляем тот же контроллер для нативной проверки.
if not app.isUIAvailable then return ZX end

local sprite = app.activeSprite
if not sprite then app.alert("Откройте документ 256×192 в режиме Indexed."); return end
local valid, reason = pcall(validate, sprite)
if not valid then showError(reason); return end

-- Закрываем прежнюю панель перед повторным запуском скрипта.
if _G.zxSpectrumWindow then _G.zxSpectrumWindow:close() end
if _G.zxSpectrumProbeDialog then _G.zxSpectrumProbeDialog:close() end

local controller, timer, dialog
local closing = false
local errorWindow, errorPage, errorSignature = nil, 1, nil
local errorButtons = {}
local PAGE_SIZE, COLUMNS = 48, 4
local pendingStatus, pendingFocus
local openErrorsRequested = false
local pendingChannels
local autoRequested = false
local autoResult = ""
local bindActiveDocument, zxRequested
local waitingForDocument = false

local function run(action)
  local ok, err = pcall(action)
  if not ok then showError(err) end
end

-- Обновляем постоянное окно ошибок, не закрывая его при переходе на выбранную клетку.
local function refreshErrorList()
  if closing or not controller then return end
  local cells = controller.enabled and controller.invalidCells() or {}
  local pages = math.max(1, math.ceil(#cells / PAGE_SIZE))
  errorPage = math.max(1, math.min(errorPage, pages))
  local signature = tostring(controller.enabled) .. ":" .. errorPage
  for _, cell in ipairs(cells) do signature = signature .. "/" .. cell.x .. "," .. cell.y end
  if signature == errorSignature then return end
  errorSignature = signature
  dialog:modify { id = "errors", enabled = controller.enabled and #cells > 0 }
  if not errorWindow then return end

  errorWindow:modify { id = "count", text = "Клеток с ошибками: " .. #cells }
  errorWindow:modify { id = "auto", enabled = controller.enabled and #cells > 0 }
  errorWindow:modify { id = "autoResult", text = autoResult }
  local buttons = {}
  for slot = 1, PAGE_SIZE do
    local cell = cells[(errorPage - 1) * PAGE_SIZE + slot]
    buttons[slot] = cell
    errorWindow:modify {
      id = "cell" .. slot,
      text = cell and string.format("(%02d,%02d)", cell.x, cell.y) or "(--,--)",
      enabled = cell ~= nil
    }
  end
  errorButtons = buttons
  errorWindow:modify { id = "previous", enabled = errorPage > 1 }
  errorWindow:modify { id = "page", text = errorPage .. " / " .. pages }
  errorWindow:modify { id = "next", enabled = errorPage < pages }
end

local function openErrorWindow()
  if closing or not controller or not controller.documentAlive() then return end
  if errorWindow then return end
  errorPage = 1
  local window
  window = Dialog {
    title = "Ошибки ZX",
    onclose = function()
      if errorWindow ~= window then return end
      errorWindow, errorSignature, pendingFocus = nil, nil, nil
      autoRequested = false
      errorButtons = {}
    end
  }
  errorWindow = window
  errorWindow:label { id = "count", text = "Клеток с ошибками: 0" }
  errorWindow:newrow()
  errorWindow:button { id = "auto", text = "Автоисправить", onclick = function()
    if not closing and errorWindow == window then autoRequested = true end
  end }
  errorWindow:newrow()
  errorWindow:label { id = "autoResult", text = autoResult }
  errorWindow:newrow()
  errorWindow:label { text = "(X,Y), координаты от нуля" }
  errorWindow:newrow()
  for slot = 1, PAGE_SIZE do
    local selectedSlot = slot
    errorWindow:button {
      id = "cell" .. slot, text = "(00,00)",
      onclick = function()
        if closing or errorWindow ~= window then return end
        local cell = errorButtons[selectedSlot]
        if cell then pendingFocus = { x = cell.x, y = cell.y } end
      end
    }
    if slot % COLUMNS == 0 then errorWindow:newrow() end
  end
  errorWindow:button { id = "previous", text = "Назад", onclick = function()
    if closing or errorWindow ~= window then return end
    errorPage = errorPage - 1; errorSignature = nil
  end }
  errorWindow:button { id = "page", text = "1 / 1", enabled = false, onclick = function() end }
  errorWindow:button { id = "next", text = "Вперёд", onclick = function()
    if closing or errorWindow ~= window then return end
    errorPage = errorPage + 1; errorSignature = nil
  end }
  errorSignature = nil
  refreshErrorList()
  errorWindow:show { wait = false }
end

-- Создаём только управление режимом, изображение остаётся на штатном холсте.
dialog = Dialog {
  title = "ZX Spectrum",
  onclose = function()
    if closing then return end
    closing = true
    if timer then timer:stop() end
    if errorWindow then errorWindow:close() end
    if controller then
      local ok, err = pcall(controller.close)
      if not ok then print("ZX cleanup: " .. tostring(err)) end
    end
    _G.zxSpectrumWindow = nil
    _G.zxSpectrumActions = nil
  end
}
_G.zxSpectrumWindow = dialog
dialog:check {
  id = "zx", text = "ZX", selected = false,
  onclick = function()
    zxRequested = dialog.data.zx == true
  end
}
dialog:newrow()
local function channelClick()
  pendingChannels = { ink = dialog.data.ink, paper = dialog.data.paper, bright = dialog.data.bright }
end
for _, channel in ipairs { "ink", "paper", "bright", "flash" } do
  dialog:check { id = channel, text = channel:upper(), selected = channel ~= "flash",
    enabled = channel ~= "flash", onclick = channelClick }
end
dialog:newrow()
dialog:label { id = "context", text = "ЛКМ — INK, ПКМ — PAPER" }
dialog:newrow()
dialog:label { id = "status", text = "ZX OFF" }
dialog:newrow()
dialog:button { id = "errors", text = "Список ошибок...", enabled = false, onclick = function()
  if not closing then openErrorsRequested = true end
end }
dialog:newrow()

-- Выбираем файл отдельно от холста, не создавая второго окна изображения.
local function fileDialog(save)
  local picker = Dialog { title = save and "Export SCR" or "Import SCR" }
  picker:file { id = "path", title = "SCR", filename = "screen.scr",
    open = not save, save = save, filetypes = { "scr" } }
  picker:button { text = "OK", onclick = function()
    run(function()
      local path = picker.data.path
      assert(path and path ~= "", "Выберите файл SCR.")
      if save then
        local bytes = controller.bytes()
        if app.fs.isFile(path) then
          if app.alert { title = "Export SCR", text = "Перезаписать файл?",
            buttons = { "Да", "Нет" } } ~= 1 then return end
        end
        local file = assert(io.open(path, "wb"))
        local ok, err = file:write(bytes)
        file:close()
        assert(ok, err)
      else
        local file = assert(io.open(path, "rb"))
        local bytes = file:read("*a")
        file:close()
        controller.import(bytes)
      end
      picker:close()
    end)
  end }
  picker:button { text = "Cancel" }
  picker:show()
end
dialog:button { text = "Import SCR", onclick = function() fileDialog(false) end }
dialog:newrow()
dialog:button { text = "Export SCR", onclick = function() fileDialog(true) end }

-- Подписки каждого контроллера относятся только к одному документу и снимаются при перепривязке.
local function attachDocument(target)
  local bound
  bound = ZX.attach(target, function(message, enabled)
    if closing or controller ~= bound then return end
    -- События документа только передают статус, интерфейс обновляется из таймера.
    pendingStatus = { message = message, enabled = enabled }
  end)
  return bound
end
controller = attachDocument(sprite)

-- Галочка ZX включает режим для текущего холста, сохраняя настройки каналов панели.
bindActiveDocument = function()
  local target = app.activeSprite
  assert(target, "Откройте документ 256×192 в режиме Indexed.")
  validate(target)
  if controller.documentAlive() and controller.sprite == target then return end
  local channels = pendingChannels or controller.channels
  controller.close()
  sprite = target
  controller = attachDocument(target)
  controller.setChannels(channels)
  pendingStatus, pendingFocus = nil, nil
  autoRequested, openErrorsRequested = false, false
  autoResult, errorSignature, errorPage, errorButtons = "", nil, 1, {}
  waitingForDocument = false
  for _, id in ipairs { "ink", "paper", "bright" } do dialog:modify { id = id, enabled = true } end
end

-- Команды вспомогательных скриптов доступны для назначения штатных горячих клавиш Aseprite.
_G.zxSpectrumActions = {
  toggle = function(channel)
    if closing or not controller then return end
    local channels = pendingChannels or { ink = controller.channels.ink,
      paper = controller.channels.paper, bright = controller.channels.bright }
    assert(channels[channel] ~= nil, "Неизвестный канал ZX.")
    channels[channel] = not channels[channel]
    pendingChannels = channels
  end
}

-- Обрабатываем завершённый мазок после выхода из события истории Aseprite.
timer = Timer { interval = 0.02, ontick = function()
  if closing then return end
  -- Применяем выбор документа после выхода из обработчика флажка.
  if zxRequested ~= nil then
    local requested = zxRequested
    zxRequested = nil
    run(function()
      if requested then bindActiveDocument(); controller.enable()
      elseif controller.documentAlive() then controller.disable() end
    end)
    dialog:modify { id = "zx", selected = controller.enabled }
  end
  if not controller.documentAlive() then
    controller.close()
    -- Панель остаётся доступна для следующего открытого документа без перезапуска скрипта.
    if not waitingForDocument then
      waitingForDocument = true
      if errorWindow then errorWindow:close() end
      pendingStatus, pendingFocus = nil, nil
      autoRequested, openErrorsRequested = false, false
      dialog:modify { id = "zx", selected = false, enabled = true }
      dialog:modify { id = "errors", enabled = false }
      for _, id in ipairs { "ink", "paper", "bright" } do dialog:modify { id = id, enabled = false } end
      dialog:modify { id = "status", text = "Откройте холст и включите ZX" }
    end
    return
  end
  run(controller.flush)
  run(function()
    if autoRequested then
      autoRequested = false
      local result = controller.autoCorrect()
      autoResult = string.format("Исправлено: %d. Осталось: %d.", result.fixed, result.remaining)
      errorSignature = nil
    end
    if pendingChannels then
      local channels = pendingChannels
      pendingChannels = nil
      controller.setChannels(channels)
      for _, id in ipairs { "ink", "paper", "bright" } do
        dialog:modify { id = id, selected = controller.channels[id] }
      end
      local c = controller.channels
      local context = c.ink and c.paper and "ЛКМ — INK, ПКМ — PAPER" or
        (c.ink and "Рисунок: ЛКМ — чёрный, ПКМ — белый" or
        (c.paper and "PAPER: цвет меняется в клетке 8×8" or
        (c.bright and "BRIGHT: ЛКМ — вкл., ПКМ — выкл." or "Все каналы скрыты")))
      dialog:modify { id = "context", text = context }
    end
    controller.processNativePicks()
    controller.refreshView()
  end)
  run(controller.refreshDiagnostics)
  -- Меняем список и центрируем холст после завершения событий документа и кнопок.
  run(function()
    if pendingFocus then
      local cell = pendingFocus
      pendingFocus = nil
      controller.focusCell(cell.x, cell.y)
    end
    if pendingStatus then
      local status = pendingStatus
      pendingStatus = nil
      dialog:modify { id = "status", text = status.message }
      dialog:modify { id = "zx", selected = status.enabled }
    end
    if openErrorsRequested then
      openErrorsRequested = false
      openErrorWindow()
    end
    refreshErrorList()
  end)
  if controller.lastWarning then
    local warning = controller.lastWarning
    controller.lastWarning = nil
    -- Размещаем каждый тезис отдельной строкой штатного предупреждения.
    local lines = {}
    for line in warning:gmatch("[^\n]+") do lines[#lines + 1] = line end
    app.alert { title = "ZX Spectrum", text = lines }
  end
  if controller.lastError then
    local err = controller.lastError
    controller.lastError = nil
    showError(err)
  end
end }
timer:start()
dialog:show { wait = false }
