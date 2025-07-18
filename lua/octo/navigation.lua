local gh = require "octo.gh"
local queries = require "octo.gh.queries"
local utils = require "octo.utils"

local vim = vim

local M = {}

--[[
Opens a url in your default browser, bypassing gh.

@param url The url to open.
]]
---@param url string
function M.open_in_browser_raw(url)
  local os_name = vim.loop.os_uname().sysname
  local is_windows = vim.loop.os_uname().version:match "Windows"

  if os_name == "Darwin" then
    os.execute("open " .. url)
  elseif os_name == "Linux" then
    os.execute("xdg-open " .. url)
  elseif is_windows then
    os.execute("start " .. url)
  end
end

---@param kind? "issue"|"pull_request"|"discussion"|"repo"|"gist"|"project"|"workflow_run"
---@param repo? string|{ url: string }
---@param number? integer|string
function M.open_in_browser(kind, repo, number)
  local cmd ---@type string
  local remote = utils.get_remote_host()
  if not remote then
    utils.error "Cannot find repo remote host"
    return
  end

  if not kind and not repo then
    local buffer = utils.get_current_buffer()
    if not buffer then
      local owner_repo = utils.get_remote_name()
      if not owner_repo then
        utils.error "No remote repository found"
        return
      end
      cmd = string.format("gh repo view --web %s", owner_repo)
      ---@diagnostic disable-next-line: param-type-mismatch
      return pcall(vim.cmd, "silent !" .. cmd)
    end
    if buffer:isPullRequest() then
      cmd = string.format("gh pr view --web -R %s/%s %d", remote, buffer.repo, buffer.number)
    elseif buffer:isIssue() then
      cmd = string.format("gh issue view --web -R %s/%s %d", remote, buffer.repo, buffer.number)
    elseif buffer:isRepo() then
      cmd = string.format("gh repo view --web %s/%s", remote, buffer.repo)
    elseif buffer:isDiscussion() then
      ---@type string
      local url = buffer.node.url
      M.open_in_browser_raw(url)
      return
    end
  else
    if kind == "pr" or kind == "pull_request" then
      cmd = string.format("gh pr view --web -R %s/%s %d", remote, repo, number)
    elseif kind == "issue" then
      cmd = string.format("gh issue view --web -R %s/%s %d", remote, repo, number)
    elseif kind == "repo" then
      assert(repo, "repo is required")
      cmd = string.format("gh repo view --web %s", repo.url)
    elseif kind == "gist" then
      cmd = string.format("gh gist view --web %s", number)
    elseif kind == "project" then
      cmd = string.format("gh project view --owner %s --web %s", repo, number)
    elseif kind == "workflow_run" then
      cmd = string.format("gh run view %s --web", number)
    end
  end
  ---@diagnostic disable-next-line: param-type-mismatch
  pcall(vim.cmd, "silent !" .. cmd)
end

local function open_file_if_found(path, line)
  local stat = vim.loop.fs_stat(path)
  if stat and stat.type then
    vim.cmd("e " .. path)
    vim.api.nvim_win_set_cursor(0, { line, 0 })
    return true
  end
  return false
end

function M.go_to_file()
  local bufnr = vim.api.nvim_get_current_buf()
  ---@type string?
  local path = ""
  local line = vim.api.nvim_win_get_cursor(0)[1]
  if utils.in_diff_window(bufnr) then
    _, path = utils.get_split_and_path(bufnr)
  else
    local buffer = octo_buffers[bufnr]
    if not buffer then
      return
    end
    if not buffer:isPullRequest() then
      return
    end
    local _thread = buffer:get_thread_at_cursor()
    path, line = _thread.path, _thread.line
  end
  local result = open_file_if_found(utils.path_join { vim.fn.getcwd(), path }, line)
  if not result then
    local cmd = "git rev-parse --show-toplevel"
    local git_root = vim.fn.system(cmd):gsub("\n", "")
    result = open_file_if_found(utils.path_join { git_root, path }, line)
  end
  if not result then
    utils.error "Cannot find file in CWD or git path"
  end
end

function M.go_to_issue()
  local buffer = utils.get_current_buffer()
  if not buffer then
    return
  end
  local repo, number = utils.extract_issue_at_cursor(buffer.repo)
  if not repo or not number then
    return
  end
  local owner, name = utils.split_repo(repo)

  gh.api.graphql {
    query = queries.issue_kind,
    fields = { owner = owner, name = name, number = number },
    jq = ".data.repository.issueOrPullRequest.__typename",
    opts = {
      cb = gh.create_callback {
        failure = utils.print_err,
        success = function(kind)
          if kind == "Issue" then
            utils.get_issue(number, repo)
          elseif kind == "PullRequest" then
            utils.get_pull_request(number, repo)
          end
        end,
      },
    },
  }
end

function M.next_comment()
  local buffer = utils.get_current_buffer()
  if buffer.kind then
    local cursor = vim.api.nvim_win_get_cursor(0)
    local current_line = cursor[1]
    local lines = utils.get_sorted_comment_lines(buffer.bufnr)
    if not buffer:isReviewThread() then
      -- skil title and body
      lines = utils.tbl_slice(lines, 3, #lines)
    end
    if not lines or not current_line then
      return
    end

    if #lines == 0 then
      return
    end

    ---@type integer?
    local target
    if current_line < lines[1] + 1 then
      -- go to first comment
      target = lines[1] + 1
    elseif current_line > lines[#lines] + 1 then
      -- do not move
      target = current_line - 1
    else
      for i = #lines, 1, -1 do
        if current_line >= lines[i] + 1 then
          target = lines[i + 1] + 1
          break
        end
      end
    end
    vim.api.nvim_win_set_cursor(0, { target + 1, cursor[2] })
  end
end

function M.prev_comment()
  local buffer = utils.get_current_buffer()
  if buffer.kind then
    local cursor = vim.api.nvim_win_get_cursor(0)
    local current_line = cursor[1]
    local lines = utils.get_sorted_comment_lines(buffer.bufnr)
    lines = utils.tbl_slice(lines, 3, #lines)
    if not lines or not current_line then
      return
    end

    if #lines == 0 then
      return
    end

    ---@type integer?
    local target
    if current_line > lines[#lines] + 2 then
      -- go to last comment
      target = lines[#lines] + 1
    elseif current_line <= lines[1] + 2 then
      -- do not move
      target = current_line - 1
    else
      for i = 1, #lines, 1 do
        if current_line <= lines[i] + 2 then
          target = lines[i - 1] + 1
          break
        end
      end
    end
    vim.api.nvim_win_set_cursor(0, { target + 1, cursor[2] })
  end
end

return M
