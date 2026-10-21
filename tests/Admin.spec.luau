--!strict
-- Admin tools, the pure parts (PLAN.md Phase 12 "Admin tools gated by Config/Admins.luau"; docs/phase-12-contracts.md
-- "Ads, analytics, admin"; Services/AdminService):
--   * who is an admin (the list; anyone in Studio only while Config/Designer.studioCountsAsAdmin is on),
--   * what each action needs (kick never yourself or another admin; despawn needs a car out; hide needs an id;
--     nothing at all for a non-admin) and that every refusal has words,
--   * the log keeps the newest entries in order and cuts long lines on a character boundary,
--   * the AdminAction remote accepts only the four actions (no grants: cash and credits stay Studio-only through the
--     dev remotes),
--   * the admin panel's tap targets are at least 44 px.
-- Pure: runs in Edit mode.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local Admins = require(ReplicatedStorage.Shared.Config.Admins)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Net = require(ReplicatedStorage.Shared.Net)
local AdminService = require(ServerScriptService.Server.Services.AdminService)

local Client = StarterPlayer.StarterPlayerScripts.Client
local AdminStyle = require(Client.UI.Admin.AdminStyle)
local Theme = require(Client.UI.Theme)

local ADMIN = 100
local PLAYER = 200
local OTHER_ADMIN = 300

local function facts(overrides: { [string]: any }?): AdminService.Facts
	local base: AdminService.Facts = {
		isAdmin = true,
		actorUserId = ADMIN,
		targetPresent = true,
		targetIsAdmin = false,
		hasCar = true,
	}
	for key, value in overrides or {} do
		(base :: any)[key] = value
	end
	return base
end

local function why(action: string, target: number?, ref: string?, overrides: { [string]: any }?): string
	local _, code = AdminService.decide(action, target, ref, facts(overrides))
	return code
end

return function(t: Harness.Api)
	t.describe("AdminService.isAdminFor", function()
		t.it("lets only listed users in on live servers", function()
			t.expect(AdminService.isAdminFor(ADMIN, { ADMIN }, false, true)).toBe(true)
			t.expect(AdminService.isAdminFor(PLAYER, { ADMIN }, false, true)).toBe(false)
			t.expect(AdminService.isAdminFor(PLAYER, {}, false, true)).toBe(false)
		end)

		t.it("lets anyone in, in Studio, only while Studio counts as admin", function()
			t.expect(AdminService.isAdminFor(PLAYER, { ADMIN }, true, true)).toBe(true)
			t.expect(AdminService.isAdminFor(PLAYER, { ADMIN }, true, false)).toBe(false)
		end)

		t.it("ships a list of real UserIds", function()
			t.expect(#Admins.userIds).toBeGreaterThan(0)
			for _, userId in Admins.userIds do
				t.expect(type(userId) == "number" and userId > 0 and userId % 1 == 0).toBe(true)
			end
		end)
	end)

	t.describe("AdminService.decide", function()
		t.it("refuses everything to a non-admin, before anything else", function()
			for _, action in { "kick", "despawn", "logs", "hideDesign" } do
				t.expect(why(action, PLAYER, "ref", { isAdmin = false })).toBe("notAdmin")
			end
		end)

		t.it("kicks a player here, never yourself or another admin", function()
			t.expect(why("kick", PLAYER)).toBe("ok")
			t.expect(why("kick", nil)).toBe("noTarget")
			t.expect(why("kick", PLAYER, nil, { targetPresent = false })).toBe("notHere")
			t.expect(why("kick", ADMIN)).toBe("self")
			t.expect(why("kick", OTHER_ADMIN, nil, { targetIsAdmin = true })).toBe("protected")
		end)

		t.it("puts a car away only when the player has one out (your own included)", function()
			t.expect(why("despawn", PLAYER)).toBe("ok")
			t.expect(why("despawn", ADMIN)).toBe("ok")
			t.expect(why("despawn", PLAYER, nil, { hasCar = false })).toBe("noCar")
			t.expect(why("despawn", nil)).toBe("noTarget")
			t.expect(why("despawn", PLAYER, nil, { targetPresent = false })).toBe("notHere")
		end)

		t.it("hides only with an id, and always shows the log", function()
			t.expect(why("hideDesign", nil, "abc")).toBe("ok")
			t.expect(why("hideDesign", nil, nil)).toBe("noRef")
			t.expect(why("hideDesign", nil, "   ")).toBe("noRef")
			t.expect(why("logs", nil, nil, { targetPresent = false })).toBe("ok")
		end)

		t.it("refuses anything else, grants included", function()
			for _, action in { "grantCash", "grantCredits", "ban", "" } do
				t.expect(why(action, PLAYER, "ref")).toBe("unknown")
			end
		end)

		t.it("has plain words for every answer", function()
			for _, code in
				{ "notAdmin", "noTarget", "notHere", "self", "protected", "noCar", "noRef", "unknown", "unavailable" }
			do
				t.expect(type(AdminService.MESSAGES[code])).toBe("string")
			end
			t.expect(type(AdminService.MESSAGES.kickReason)).toBe("string")
		end)
	end)

	t.describe("The admin log", function()
		t.it("keeps the newest entries, oldest first, as copies", function()
			local ring = AdminService.newRing(3)
			for i = 1, 5 do
				ring.push({ at = i, kind = "admin", text = `line {i}` })
			end
			local list = ring.list()
			t.expect(#list).toBe(3)
			t.expect(list[1].text).toBe("line 3")
			t.expect(list[3].text).toBe("line 5")
			list[1].text = "changed"
			t.expect(ring.list()[1].text).toBe("line 3")
			t.expect(ring.size()).toBe(3)
		end)

		t.it("cuts long lines on a character boundary", function()
			local short = "all fine"
			t.expect(AdminService.clip(short)).toBe(short)
			local long = string.rep("é", 400)
			local cut = AdminService.clip(long)
			t.expect(utf8.len(cut)).toBe(300)
			local broken = string.rep("a", 350) .. "\255"
			t.expect(#AdminService.clip(broken)).toBe(300)
		end)
	end)

	t.describe("The AdminAction remote", function()
		t.it("accepts the four actions and nothing else", function()
			local spec = Net.declared().AdminAction
			t.expect(spec ~= nil and spec.kind == "function" and spec.direction == "toServer").toBe(true)
			for _, action in { "kick", "despawn", "logs", "hideDesign" } do
				t.expect(spec.validate({ action = action, targetUserId = PLAYER })).toBe(true)
			end
			t.expect(spec.validate({ action = "grantCash", targetUserId = PLAYER })).toBe(false)
			t.expect(spec.validate({ action = "kick", targetUserId = -1 })).toBe(false)
		end)
	end)

	t.describe("The admin panel", function()
		t.it("keeps every tap target at least 44 px", function()
			local floor = Theme.size.touchTarget
			t.expect(floor >= 44).toBe(true)
			t.expect(AdminStyle.toggle.size.X >= floor and AdminStyle.toggle.size.Y >= floor).toBe(true)
			t.expect(AdminStyle.sheet.closeSize.X >= floor and AdminStyle.sheet.closeSize.Y >= floor).toBe(true)
			t.expect(Theme.size.buttonHeight >= floor).toBe(true)
		end)

		t.it("offers Studio grants only as fixed amounts", function()
			t.expect(#AdminStyle.studioCash).toBeGreaterThan(0)
			t.expect(#AdminStyle.studioCredits).toBeGreaterThan(0)
		end)
	end)
end
