--!strict
-- No Robux price is written anywhere in the game's code (PLAN.md Phase 12 acceptance; CLAUDE.md hard rule 6;
-- docs/phase-12-contracts.md "Ground rules"): every price a player reads comes from MarketplaceService, so Managed
-- Pricing and price tests can change it. This reads the source of every script under ReplicatedStorage.Shared,
-- ServerScriptService.Server and StarterPlayer.StarterPlayerScripts.Client and fails on an amount written next to
-- "R$", "Robux" or the Robux icon, or a "robux = <number>"-style field. Comments count too: an example price in a
-- comment is how a hard-coded one starts. Grants (credits per pack, cash per pack) are fine: they aren't prices.
-- Reads Script.Source, so it runs in Edit mode (the command bar or Studio MCP execute_luau).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local Harness = require(ReplicatedStorage.Shared.Testing.Harness)

-- Lua patterns, matched against each source line in lower case.
local PATTERNS: { string } = {
	"r%$%s*%d", -- R$ 99, R$99
	"%d%s*r%$", -- 99 R$
	"%d[%d,%.]*%s*robux", -- 99 Robux, 1,200 robux
	"robux%s*[=:]%s*%d", -- robux = 99, PriceInRobux = 99, Robux: 99
	"\\u{e002}%s*%d", -- the Robux icon written as an escape, then an amount: "\u{E002} 99"
	"\u{E002}%s*%d", -- the Robux icon itself, then an amount
}

local MAX_SHOWN = 10 -- hits listed in a failure

export type Hit = { path: string, line: number, text: string }

-- The lines of `source` that look like a hard-coded Robux price.
local function scan(path: string, source: string): { Hit }
	local hits: { Hit } = {}
	local number = 0
	for line in string.gmatch(source .. "\n", "([^\n]*)\n") do
		number += 1
		local lower = string.lower(line)
		for _, pattern in PATTERNS do
			if string.find(lower, pattern) ~= nil then
				table.insert(hits, { path = path, line = number, text = string.gsub(line, "^%s+", "") })
				break
			end
		end
	end
	return hits
end

-- Every script under the three source roots, with its full name.
local function scripts(): { Instance }
	local playerScripts = StarterPlayer:FindFirstChild("StarterPlayerScripts")
	local roots: { Instance } = {}
	for _, root in
		{
			ReplicatedStorage:FindFirstChild("Shared"),
			ServerScriptService:FindFirstChild("Server"),
			if playerScripts ~= nil then playerScripts:FindFirstChild("Client") else nil,
		} :: { any }
	do
		if typeof(root) == "Instance" then
			table.insert(roots, root)
		end
	end
	local found: { Instance } = {}
	for _, root in roots do
		if root:IsA("LuaSourceContainer") then
			table.insert(found, root)
		end
		for _, item in root:GetDescendants() do
			if item:IsA("LuaSourceContainer") then
				table.insert(found, item)
			end
		end
	end
	return found
end

return function(t: Harness.Api)
	t.describe("No hard-coded Robux prices", function()
		t.it("catches the shapes a written price takes", function()
			for _, bad in
				{
					'local text = "R$ 99"',
					"-- costs 99 Robux",
					"robux = 99,",
					"PriceInRobux = 400",
					"-- 1,200 robux",
					'label.Text = "\\u{E002} 250"',
					'label.Text = "\u{E002}75"',
					"price: 25 R$",
				}
			do
				t.expect(`{bad}: {#scan("sample", bad)}`).toBe(`{bad}: 1`)
			end
		end)

		t.it("leaves grants, cash and prices read from MarketplaceService alone", function()
			for _, fine in
				{
					"credits15 = { credits = 15, bonus = 3 },",
					"cash4 = { cash = 300000 },",
					'local price = if type(info) == "table" then info.PriceInRobux else nil',
					"-- Robux prices come from MarketplaceService, never from here.",
					'robux = "\\u{E002} %s",',
					"return string.format(copy.robux, amount)",
					'local pattern = "^[A-Z0-9 %-]+$"',
				}
			do
				t.expect(`{fine}: {#scan("sample", fine)}`).toBe(`{fine}: 0`)
			end
		end)

		t.it("finds no Robux price in any script", function()
			local list = scripts()
			t.expect(#list).toBeGreaterThan(0)
			local hits: { Hit } = {}
			local unreadable: { string } = {}
			for _, item in list do
				local ok, source = pcall(function(): string
					return (item :: any).Source
				end)
				if ok and type(source) == "string" then
					for _, hit in scan(item:GetFullName(), source) do
						table.insert(hits, hit)
					end
				else
					table.insert(unreadable, item:GetFullName())
				end
			end
			-- Source is only readable in Edit mode; anywhere else this check can't see the code.
			t.expect(`unreadable: {table.concat(unreadable, ", ")}`).toBe("unreadable: ")
			local shown: { string } = {}
			for index, hit in hits do
				if index > MAX_SHOWN then
					table.insert(shown, `... and {#hits - MAX_SHOWN} more`)
					break
				end
				table.insert(shown, `{hit.path}:{hit.line}: {hit.text}`)
			end
			t.expect(table.concat(shown, " | ")).toBe("")
		end)
	end)
end
