local util = require "obsidian.util"
local echo = require "obsidian.echo"
local DefaultTbl = require("obsidian.collections").DefaultTbl
local throttle = require("obsidian.async").throttle

local M = {}

---@param ui_opts obsidian.config.UIOpts
M.install_hl_groups = function(ui_opts)
  for group_name, opts in pairs(ui_opts.hl_groups) do
    vim.api.nvim_set_hl(0, group_name, opts)
  end
end

---@class ExtMark
---@field id integer|? ID of the mark, only set for marks that are actually materialized in the buffer.
---@field row integer 0-based row index to place the mark.
---@field col integer 0-based col index to place the mark.
---@field opts ExtMarkOpts Optional parameters passed directly to `nvim_buf_set_extmark()`.
local ExtMark = {}
M.ExtMark = ExtMark

---@class ExtMarkOpts
---@field end_row integer
---@field end_col integer
---@field conceal string|?
---@field hl_group string|?
---@field spell boolean|?
local ExtMarkOpts = {}
M.ExtMarkOpts = ExtMarkOpts

---@param a ExtMarkOpts
---@param b ExtMarkOpts
---@return boolean
ExtMarkOpts.__eq = function(a, b)
  -- TODO: the conceal char we get back from `nvim_buf_get_extmarks()` is mangled, e.g.
  -- "󰄱" is turned into "1\1\15", so this comparison fails.
  return a.end_row == b.end_row
    and a.end_col == b.end_col
    and a.conceal == b.conceal
    and a.hl_group == b.hl_group
    and a.spell == b.spell
end

---@param data table
---@return ExtMarkOpts
ExtMarkOpts.from_tbl = function(data)
  local self = setmetatable({}, { __index = ExtMarkOpts, __eq = ExtMarkOpts.__eq })
  self.end_row = data.end_row
  self.end_col = data.end_col
  self.conceal = data.conceal
  self.hl_group = data.hl_group
  self.spell = data.spell
  return self
end

---@param self ExtMarkOpts
---@return table
ExtMarkOpts.to_tbl = function(self)
  return {
    end_row = self.end_row,
    end_col = self.end_col,
    conceal = self.conceal,
    hl_group = self.hl_group,
    spell = self.spell,
  }
end

---@param a ExtMark
---@param b ExtMark
---@return boolean
ExtMark.__eq = function(a, b)
  return a.row == b.row and a.col == b.col and a.opts == b.opts
end

---@param id integer|?
---@param row integer
---@param col integer
---@param opts ExtMarkOpts
---@return ExtMark
ExtMark.new = function(id, row, col, opts)
  local self = setmetatable({}, { __index = ExtMark, __eq = ExtMark.__eq })
  self.id = id
  self.row = row
  self.col = col
  self.opts = opts
  return self
end

---Materialize the ExtMark if needed. After calling this the 'id' will be set if it wasn't already.
---@param self ExtMark
---@param bufnr integer
---@param ns_id integer
---@return ExtMark
ExtMark.materialize = function(self, bufnr, ns_id)
  if self.id == nil then
    self.id = vim.api.nvim_buf_set_extmark(bufnr, ns_id, self.row, self.col, self.opts:to_tbl())
  end
  return self
end

---@param self ExtMark
---@param bufnr integer
---@param ns_id integer
---@return boolean
ExtMark.clear = function(self, bufnr, ns_id)
  if self.id ~= nil then
    return vim.api.nvim_buf_del_extmark(bufnr, ns_id, self.id)
  else
    return false
  end
end

---Collect all existing (materialized) marks within a region.
---@param bufnr integer
---@param ns_id integer
---@param region_start integer|integer[]|?
---@param region_end integer|integer[]|?
---@return ExtMark[]
ExtMark.collect = function(bufnr, ns_id, region_start, region_end)
  region_start = region_start and region_start or 0
  region_end = region_end and region_end or -1
  local marks = {}
  for data in util.iter(vim.api.nvim_buf_get_extmarks(bufnr, ns_id, region_start, region_end, { details = true })) do
    local mark = ExtMark.new(data[1], data[2], data[3], ExtMarkOpts.from_tbl(data[4]))
    marks[#marks + 1] = mark
  end
  return marks
end

---Collect all existing (materialized) marks on a line (0-based).
---@param bufnr integer
---@param ns_id integer
---@param lnum integer 0-based line index
---@return ExtMark[]
ExtMark.collect_from_line = function(bufnr, ns_id, lnum)
  return ExtMark.collect(bufnr, ns_id, lnum, lnum)
end

---Clear all existing (materialized) marks with a line region.
---@param bufnr integer
---@param ns_id integer
---@param line_start integer
---@param line_end integer
ExtMark.clear_range = function(bufnr, ns_id, line_start, line_end)
  return vim.api.nvim_buf_clear_namespace(bufnr, ns_id, line_start, line_end)
end

---Clear all existing (materialized) marks on a line.
---@param bufnr integer
---@param ns_id integer
---@param line integer
ExtMark.clear_line = function(bufnr, ns_id, line)
  return ExtMark.clear_range(bufnr, ns_id, line, line + 1)
end

---@param marks ExtMark[]
---@param lnum integer
---@param ui_opts obsidian.config.UIOpts
---@return ExtMark[]
local function get_line_check_extmarks(marks, line, lnum, ui_opts)
  for char, opts in pairs(ui_opts.checkboxes) do
    -- TODO: escape `char` if needed
    if string.match(line, "^%s*- %[" .. char .. "%]") then
      local indent = util.count_indent(line)
      marks[#marks + 1] = ExtMark.new(
        nil,
        lnum,
        indent,
        ExtMarkOpts.from_tbl {
          end_row = lnum,
          end_col = indent + 5,
          conceal = opts.char,
          hl_group = opts.hl_group,
        }
      )
      break
    end
  end
  return marks
end

---@param marks ExtMark[]
---@param lnum integer
---@param ui_opts obsidian.config.UIOpts
---@return ExtMark[]
local function get_line_ref_extmarks(marks, line, lnum, ui_opts)
  local matches = util.find_refs(line, true)
  for match in util.iter(matches) do
    local m_start, m_end, m_type = unpack(match)
    if m_type == util.RefTypes.WikiWithAlias then
      -- Reference of the form [[xxx|yyy]]
      local pipe_loc = string.find(line, "|", m_start, true)
      assert(pipe_loc)
      -- Conceal everything from '[[' up to '|'
      marks[#marks + 1] = ExtMark.new(
        nil,
        lnum,
        m_start - 1,
        ExtMarkOpts.from_tbl {
          end_row = lnum,
          end_col = pipe_loc,
          conceal = "",
        }
      )
      -- Highlight the alias 'yyy'
      marks[#marks + 1] = ExtMark.new(
        nil,
        lnum,
        pipe_loc,
        ExtMarkOpts.from_tbl {
          end_row = lnum,
          end_col = m_end - 2,
          hl_group = ui_opts.reference_text.hl_group,
          spell = false,
        }
      )
      -- Conceal the closing ']]'
      marks[#marks + 1] = ExtMark.new(
        nil,
        lnum,
        m_end - 1,
        ExtMarkOpts.from_tbl {
          end_row = lnum,
          end_col = m_end,
          conceal = "",
        }
      )
    elseif m_type == util.RefTypes.Wiki then
      -- Reference of the form [[xxx]]
      -- Conceal the opening '[['
      marks[#marks + 1] = ExtMark.new(
        nil,
        lnum,
        m_start - 1,
        ExtMarkOpts.from_tbl {
          end_row = lnum,
          end_col = m_start + 1,
          conceal = "",
        }
      )
      -- Highlight the ref 'xxx'
      marks[#marks + 1] = ExtMark.new(
        nil,
        lnum,
        m_start + 1,
        ExtMarkOpts.from_tbl {
          end_row = lnum,
          end_col = m_end - 2,
          hl_group = ui_opts.reference_text.hl_group,
          spell = false,
        }
      )
      -- Conceal the closing ']]'
      marks[#marks + 1] = ExtMark.new(
        nil,
        lnum,
        m_end - 1,
        ExtMarkOpts.from_tbl {
          end_row = lnum,
          end_col = m_end,
          conceal = "",
        }
      )
    elseif m_type == util.RefTypes.Markdown then
      -- Reference of the form [yyy](xxx)
      local closing_bracket_loc = string.find(line, "]", m_start, true)
      assert(closing_bracket_loc)
      local is_url = util.is_url(string.sub(line, closing_bracket_loc + 2, m_end - 1))
      -- Conceal the opening '['
      marks[#marks + 1] = ExtMark.new(
        nil,
        lnum,
        m_start - 1,
        ExtMarkOpts.from_tbl {
          end_row = lnum,
          end_col = m_start,
          conceal = "",
        }
      )
      -- Highlight the ref 'yyy'
      marks[#marks + 1] = ExtMark.new(
        nil,
        lnum,
        m_start,
        ExtMarkOpts.from_tbl {
          end_row = lnum,
          end_col = closing_bracket_loc - 1,
          hl_group = ui_opts.reference_text.hl_group,
          spell = false,
        }
      )
      -- Conceal the ']('
      marks[#marks + 1] = ExtMark.new(
        nil,
        lnum,
        closing_bracket_loc - 1,
        ExtMarkOpts.from_tbl {
          end_row = lnum,
          end_col = closing_bracket_loc + 1,
          conceal = is_url and " " or "",
        }
      )
      -- Conceal the URL part 'xxx' with the external URL character
      marks[#marks + 1] = ExtMark.new(
        nil,
        lnum,
        closing_bracket_loc + 1,
        ExtMarkOpts.from_tbl {
          end_row = lnum,
          end_col = m_end - 1,
          conceal = is_url and ui_opts.external_link_icon.char or "",
          hl_group = ui_opts.external_link_icon.hl_group,
        }
      )
      -- Conceal the closing ')'
      marks[#marks + 1] = ExtMark.new(
        nil,
        lnum,
        m_end - 1,
        ExtMarkOpts.from_tbl {
          end_row = lnum,
          end_col = m_end,
          conceal = is_url and " " or "",
        }
      )
    elseif m_type == util.RefTypes.NakedUrl then
      -- A "naked" URL is just a URL by itself, like 'https://github.com/'
      local domain_start_loc = string.find(line, "://", m_start, true)
      assert(domain_start_loc)
      domain_start_loc = domain_start_loc + 3
      -- Conceal the "https?://" part
      marks[#marks + 1] = ExtMark.new(
        nil,
        lnum,
        m_start - 1,
        ExtMarkOpts.from_tbl {
          end_row = lnum,
          end_col = domain_start_loc - 1,
          conceal = "",
        }
      )
      -- Highlight the whole thing.
      marks[#marks + 1] = ExtMark.new(
        nil,
        lnum,
        m_start - 1,
        ExtMarkOpts.from_tbl {
          end_row = lnum,
          end_col = m_end,
          hl_group = ui_opts.reference_text.hl_group,
          spell = false,
        }
      )
    end
  end
  return marks
end

---@param lnum integer
---@param ui_opts obsidian.config.UIOpts
---@return ExtMark[]
local get_line_marks = function(line, lnum, ui_opts)
  local marks = {}
  get_line_check_extmarks(marks, line, lnum, ui_opts)
  get_line_ref_extmarks(marks, line, lnum, ui_opts)
  return marks
end

---@param bufnr integer
---@param ui_opts obsidian.config.UIOpts
local function update_extmarks(bufnr, ns_id, ui_opts)
  ---@diagnostic disable-next-line: undefined-field
  local start_time = vim.loop.hrtime()
  local n_marks_added = 0
  local n_marks_cleared = 0

  -- Collect all current marks, grouped by line.
  local cur_marks_by_line = DefaultTbl.new(function()
    return {}
  end)
  for mark in util.iter(ExtMark.collect(bufnr, ns_id)) do
    local cur_line_marks = cur_marks_by_line[mark.row]
    cur_line_marks[#cur_line_marks + 1] = mark
  end

  -- Iterate over lines (skipping code blocks) and update marks.
  local inside_code_block = false
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
  for i, line in ipairs(lines) do
    local lnum = i - 1
    local cur_line_marks = cur_marks_by_line[lnum]

    -- Check if inside a code block or at code block boundary. If not, update marks.
    if string.match(line, "^%s*```[^`]*$") then
      inside_code_block = not inside_code_block
      -- Remove any existing marks here on the boundary of a code block.
      ExtMark.clear_line(bufnr, ns_id, lnum)
      n_marks_cleared = n_marks_cleared + #cur_line_marks
    elseif not inside_code_block then
      -- Get all marks that should be materialized.
      -- Some of these might already be materialized, which we'll check below and avoid re-drawing
      -- if that's the case.
      local new_line_marks = get_line_marks(line, lnum, ui_opts)
      if #new_line_marks > 0 then
        -- Materialize new marks.
        for mark in util.iter(new_line_marks) do
          if not util.contains(cur_line_marks, mark) then
            mark:materialize(bufnr, ns_id)
            n_marks_added = n_marks_added + 1
          end
        end

        -- Clear old marks.
        for mark in util.iter(cur_line_marks) do
          if not util.contains(new_line_marks, mark) then
            mark:clear(bufnr, ns_id)
            n_marks_cleared = n_marks_cleared + 1
          end
        end
      else
        -- Remove any existing marks here since there are no new marks.
        ExtMark.clear_line(bufnr, ns_id, lnum)
        n_marks_cleared = n_marks_cleared + #cur_line_marks
      end
    else
      -- Remove any existing marks here since we're inside a code block.
      ExtMark.clear_line(bufnr, ns_id, lnum)
      n_marks_cleared = n_marks_cleared + #cur_line_marks
    end
  end

  ---@diagnostic disable-next-line: undefined-field
  local runtime = math.floor((vim.loop.hrtime() - start_time) / 1000000)
  echo.debug("Added %d new marks, cleared %d old marks in %dms", n_marks_added, n_marks_cleared, runtime)
end

---@param ui_opts obsidian.config.UIOpts
---@return function
M.get_autocmd_callback = function(ui_opts)
  local ns_id = vim.api.nvim_create_namespace "obsidian"
  M.install_hl_groups(ui_opts)
  return throttle(function(ev)
    update_extmarks(ev.buf, ns_id, ui_opts)
  end, ui_opts.update_debounce)
end

return M
