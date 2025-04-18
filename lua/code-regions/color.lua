-- lua/code-regions/color.lua
-- Handles color generation and applying background highlights.
-- Updated: Use line_hl_group for full line background color.

local api = vim.api
local config = require("code-regions.config")

local M = {}

-- Namespace for highlight extmarks
local ns_id

-- Cache for generated highlight group names and their definitions
local highlight_cache = {}

-- Helper function: Convert HEX color to RGB
local function hex_to_rgb(hex)
  hex = hex:gsub("#", "")
  if #hex ~= 6 then
    return nil -- Invalid hex
  end
  return {
    r = tonumber("0x" .. hex:sub(1, 2)) / 255,
    g = tonumber("0x" .. hex:sub(3, 4)) / 255,
    b = tonumber("0x" .. hex:sub(5, 6)) / 255,
  }
end

-- Helper function: Convert RGB color to HSL
local function rgb_to_hsl(rgb)
  if not rgb then return nil end
  local r, g, b = rgb.r, rgb.g, rgb.b
  local max = math.max(r, g, b)
  local min = math.min(r, g, b)
  local h, s, l
  l = (max + min) / 2

  if max == min then
    h, s = 0, 0 -- achromatic
  else
    local d = max - min
    s = l > 0.5 and d / (2 - max - min) or d / (max + min)
    if max == r then
      h = (g - b) / d + (g < b and 6 or 0)
    elseif max == g then
      h = (b - r) / d + 2
    else -- max == b
      h = (r - g) / d + 4
    end
    h = h / 6
  end
  return { h = h, s = s, l = l }
end

-- Helper function: Convert HSL color to RGB
local function hsl_to_rgb(hsl)
  if not hsl then return nil end
  local h, s, l = hsl.h, hsl.s, hsl.l
  local r, g, b

  if s == 0 then
    r, g, b = l, l, l -- achromatic
  else
    local function hue2rgb(p, q, t)
      if t < 0 then t = t + 1 end
      if t > 1 then t = t - 1 end
      if t < 1 / 6 then return p + (q - p) * 6 * t end
      if t < 1 / 2 then return q end
      if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
      return p
    end

    local q = l < 0.5 and l * (1 + s) or l + s - l * s
    local p = 2 * l - q
    r = hue2rgb(p, q, h + 1 / 3)
    g = hue2rgb(p, q, h)
    b = hue2rgb(p, q, h - 1 / 3)
  end
  return { r = r, g = g, b = b }
end

-- Helper function: Convert RGB color to HEX
local function rgb_to_hex(rgb)
    if not rgb then return nil end
    local function to_hex(c)
        local val = math.floor(c * 255 + 0.5)
        -- Clamp value to 0-255 range
        val = math.max(0, math.min(255, val))
        local hex = string.format("%02x", val)
        return hex -- string.format already ensures two digits
    end
    return "#" .. to_hex(rgb.r) .. to_hex(rgb.g) .. to_hex(rgb.b)
end


-- Get the background color of the 'Normal' highlight group
local function get_normal_bg()
  local ok, normal_hl = pcall(api.nvim_get_hl, 0, { name = "Normal", id = false }) -- Use id=false to get dict
  -- vim.print("Normal HL:", vim.inspect(normal_hl))
  if not ok or not normal_hl or not normal_hl.bg then
    -- Fallback if 'Normal' background isn't set
    local bg_ok, normal_nc_hl = pcall(api.nvim_get_hl, 0, { name = "NormalNC", id = false })
    if bg_ok and normal_nc_hl and normal_nc_hl.bg then
        return string.format("#%06x", normal_nc_hl.bg)
    else
        -- Guess based on Vim's background option
        return vim.o.background == 'dark' and '#202020' or '#F0F0F0'
    end
  end
  return string.format("#%06x", normal_hl.bg)
end

-- Generate a background color based on nesting level
local function generate_color(level)
  local base_bg_hex = get_normal_bg()
  local base_bg_rgb = hex_to_rgb(base_bg_hex)
  local base_bg_hsl = rgb_to_hsl(base_bg_rgb)

  if not base_bg_hsl then
    -- Fallback if color conversion fails
    vim.notify("Code Regions: Failed to convert Normal BG to HSL.", vim.log.levels.WARN)
    return config.options.colors and config.options.colors[1] or base_bg_hex
  end

  local gen_opts = config.options.color_generation

  -- Adjust lightness
  local new_l = base_bg_hsl.l + (level * gen_opts.lightness_step)
  new_l = math.max(gen_opts.min_lightness, math.min(gen_opts.max_lightness, new_l))

  -- Use specified saturation or base saturation
  local new_s = gen_opts.saturation or base_bg_hsl.s
  -- Clamp saturation
  new_s = math.max(0, math.min(1, new_s))


  local new_hsl = { h = base_bg_hsl.h, s = new_s, l = new_l }
  local new_rgb = hsl_to_rgb(new_hsl)
  local new_hex = rgb_to_hex(new_rgb)

  -- vim.print(string.format("Level %d: Base %s -> HSL %s -> New L %.2f -> New HSL %s -> RGB %s -> Hex %s",
  --   level, base_bg_hex, vim.inspect(base_bg_hsl), new_l, vim.inspect(new_hsl), vim.inspect(new_rgb), new_hex))

  return new_hex or base_bg_hex -- Fallback to base if conversion fails
end

-- Get the appropriate background color for a region level
function M.get_region_color(level)
  if not config.options.enable_colors then
    return nil
  end

  -- Use predefined colors if available
  if config.options.colors and #config.options.colors > 0 then
    local color_index = ((level - 1) % #config.options.colors) + 1
    return config.options.colors[color_index]
  end

  -- Otherwise, generate automatically
  return generate_color(level)
end

-- Define or update a highlight group for a specific background color
function M.define_highlight(level, color_hex)
  if not color_hex then return nil end

  local group_name = "CodeRegionBg" .. level
  if highlight_cache[group_name] == color_hex then
    return group_name -- Highlight already defined with the correct color
  end

  -- Define the highlight group
  -- Use guibg for GUI clients and ctermbg for terminals
  -- Note: ctermbg support might be limited depending on terminal capabilities
  -- Ensure foreground isn't overridden unless necessary
  api.nvim_set_hl(0, group_name, { guibg = color_hex, default = true })
  -- Optional: Add ctermbg support if needed, requires color approximation
  -- local approx_cterm_color = approximate_cterm_color(color_hex)
  -- api.nvim_set_hl(0, group_name, { guibg = color_hex, ctermbg = approx_cterm_color, default = true })

  highlight_cache[group_name] = color_hex -- Cache the definition
  -- vim.print("Defined highlight:", group_name, color_hex)
  return group_name
end

-- Apply background highlight extmark to a range of lines
function M.apply_highlight(bufnr, start_line, end_line, level)
  if not config.options.enable_colors then
    return
  end
  if not ns_id then
      ns_id = api.nvim_create_namespace("code_regions_hl")
  end

  local color_hex = M.get_region_color(level)
  if not color_hex then return end -- No color to apply

  local hl_group = M.define_highlight(level, color_hex)
  if not hl_group then return end -- Failed to define highlight

  -- Apply the extmark covering the region's lines
  -- Apply from line *after* start marker to line *before* end marker
  local mark_start_line = start_line -- 0-indexed start (line *after* the start marker)
  local mark_end_line = end_line - 1 -- 0-indexed end (line *before* the end marker)

  -- Ensure start is not after end
  if mark_start_line >= mark_end_line then return end

  -- vim.print(string.format("Applying highlight '%s' (%s) to lines %d-%d (0-indexed)",
  --   hl_group, color_hex, mark_start_line, mark_end_line - 1)) -- Log end_row which is exclusive

  -- *** CHANGE: Use line_hl_group instead of hl_group ***
  pcall(api.nvim_buf_set_extmark, bufnr, ns_id, mark_start_line, 0, {
    end_row = mark_end_line, -- end_row is exclusive
    end_col = -1, -- Apply to whole line width
    line_hl_group = hl_group, -- Apply highlight to the entire line background
    priority = 10, -- Low priority
    strict = false,
  })
end

-- Clear all highlight extmarks for a buffer
function M.clear_highlights(bufnr)
    if not ns_id then
        ns_id = api.nvim_create_namespace("code_regions_hl")
    else
        -- Only clear if ns_id actually exists
        pcall(api.nvim_buf_clear_namespace, bufnr, ns_id, 0, -1)
    end
    -- Clear the highlight definition cache as colors might change (e.g., theme switch)
    highlight_cache = {}
end

return M

