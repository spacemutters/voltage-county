--!strict
-- Ads (PLAN.md Phase 12 and §11 "Ads"; docs/phase-12-contracts.md "Ads, analytics, admin"). Read by
-- Services/AdsService, Dev/MapBuilder (the billboards' ad units and posters), Services/AnalyticsService and the specs.
--
-- Fair monetization (CLAUDE.md hard rule 6): ads go only through Roblox's own ad APIs, and only when Roblox says an
-- ad can show. Checked on the Roblox docs on 2026-10-20:
--   Billboards   an AdGui (AdShape HorizontalRectangle) on one face of a block part in the Workspace. That face must
--                be at least 8 x 4.5 studs and at most 32 x 18 studs, with no other AdGui or SurfaceGui on it and
--                nothing in front of it. Roblox decides when an ad is served; when none is (an ineligible viewer, no
--                ad to show) the AdGui shows its FallbackImage (Roblox's own default image when that is empty).
--                Eligible once the game has about 2,000 unique visitors a month and an approved maturity
--                questionnaire, with an ID-verified 13+ owner using 2-step verification (§11).
--   Rewarded     the client asks AdService:GetAdAvailabilityNowAsync(Enum.AdFormat.RewardedVideo) and offers the
--                ad only while it answers IsAvailable (good for one play); the server turns a developer product into
--                an AdReward (CreateAdRewardFromDevProductId) and plays it (ShowRewardedVideoAdAsync); the reward
--                then arrives as an ordinary ProcessReceipt for that product. Rewards may never be random.
--
-- Switches. Billboards show their brand poster on both faces until `billboards.serveAds` is true (set it once the
-- game is eligible) AND the live `billboards` flag (Config/FeatureFlags) is on AND that brand's poster has an uploaded
-- `image`; then the ad face holds only the AdGui, which falls back to that image whenever no ad is served.
-- Rewarded video is offered only while the live `rewardedAds` flag is on (off by default) and its product exists.
-- A flag missing from Config/FeatureFlags reads as off here.
--
-- Pure data: no requires. tests/Ads.spec checks every brand has a poster and every poster is readable.

-- An in-game poster for one of the game's own brands (Config/Brands): its name and a line under it, painted on the
-- billboard when no ad is served. `image` is an uploaded poster image ("rbxassetid://...") the ad unit falls back to
-- once Davis uploads one; while it is "" that brand's billboards stay posters (no ads), so a billboard with no ad
-- served never shows Roblox's generic default image.
export type Poster = {
	tagline: string,
	background: Color3, -- the panel's colour
	title: Color3, -- the brand name (4.5:1 or better on the background; tests/Ads.spec checks)
	text: Color3, -- the tagline (the same floor)
	image: string,
}

export type Billboards = {
	serveAds: boolean,
	flag: string,
	tag: string,
	idAttribute: string,
	brandAttribute: string,
	adUnitName: string,
	adFace: Enum.NormalId,
	posterFace: Enum.NormalId,
	frontPosterPrefix: string,
	minFace: Vector2,
	maxFace: Vector2,
	enableVideoAds: boolean,
	titleCenter: Vector2,
	titleSize: Vector2,
	taglineCenter: Vector2,
	taglineSize: Vector2,
	posters: { [string]: Poster },
}

export type RewardedVideo = {
	flag: string,
	productKey: string,
	productId: number,
	placementId: number,
	credits: number,
	readyAttribute: string,
	store: string,
	studioStore: string,
	keyPrefix: string,
	reason: string,
	messages: { [string]: string },
}

export type Ads = {
	billboards: Billboards,
	rewardedVideo: RewardedVideo,
	productIds: () -> { [string]: number },
}

local WHITE = Color3.fromRGB(246, 246, 242)
local AMBER = Color3.fromRGB(255, 214, 128)

local function poster(tagline: string, background: Color3): Poster
	return { tagline = tagline, background = background, title = WHITE, text = AMBER, image = "" }
end

local Ads: Ads

local function productIds(): { [string]: number }
	local rewarded = Ads.rewardedVideo
	return { [rewarded.productKey] = rewarded.productId }
end

Ads = {
	billboards = {
		-- false until the game is eligible for immersive ads (§11): every billboard shows its poster. Once true, the
		-- `billboards` flag is the live kill switch.
		serveAds = false,
		flag = "billboards", -- Config/FeatureFlags name
		tag = "Billboard", -- CollectionService tag on every billboard panel (Dev/MapBuilder)
		idAttribute = "BillboardId", -- the panel's Config/MapLayout billboard id
		brandAttribute = "BrandId", -- whose poster it carries (a Config/Brands id)
		adUnitName = "AdUnit", -- the AdGui on the panel's ad face
		adFace = Enum.NormalId.Front, -- the face with the AdGui: it faces the traffic coming toward it
		posterFace = Enum.NormalId.Back, -- the brand poster, for the traffic going the other way
		-- While ads are off, AdsService copies the poster onto the ad face under these names (and removes the copies
		-- again before the AdGui switches on, so that face never holds an AdGui and a SurfaceGui at once).
		frontPosterPrefix = "FrontPoster",
		-- Roblox's size limits for the ad face, in studs (width x height). Every MapLayout billboard sits inside them.
		minFace = Vector2.new(8, 4.5),
		maxFace = Vector2.new(32, 18),
		enableVideoAds = false, -- image ads only until Davis opts into video ads
		-- The poster's two lines, as fractions of the face (centre and size).
		titleCenter = Vector2.new(0.5, 0.38),
		titleSize = Vector2.new(0.86, 0.4),
		taglineCenter = Vector2.new(0.5, 0.76),
		taglineSize = Vector2.new(0.8, 0.18),
		posters = {
			ohm = poster("Charge ahead.", Color3.fromRGB(18, 54, 86)),
			halden = poster("Gets you there, every day.", Color3.fromRGB(34, 68, 48)),
			ironwood = poster("Built to haul.", Color3.fromRGB(74, 46, 24)),
			aldermoor = poster("Arrive in quiet comfort.", Color3.fromRGB(36, 36, 48)),
			kaze = poster("Light. Quick. Yours.", Color3.fromRGB(104, 22, 32)),
			brannock = poster("Feel every bit of torque.", Color3.fromRGB(64, 32, 20)),
			montevale = poster("Rare by design.", Color3.fromRGB(22, 22, 26)),
			northline = poster("Ready for the job.", Color3.fromRGB(28, 52, 78)),
		},
	},

	rewardedVideo = {
		flag = "rewardedAds", -- Config/FeatureFlags name (off by default)
		-- The developer product the reward is paid as (Creator Dashboard > Monetization > Developer Products, then
		-- Monetization > Ads: pick it as the rewarded video reward). 0 = not created yet: no ad is ever offered.
		-- It is never shown in the store; MonetizationService hands its receipts to AdsService.
		productKey = "adCredit",
		productId = 0,
		placementId = 0, -- the ad placement id from the Creator Dashboard, for per-placement reports (0 = none)
		credits = 1, -- Design Credits per ad watched, at most once per UTC day
		-- Player attribute AdsService keeps true while this player can be offered the ad today (flag on, product
		-- created, not claimed today). The store shows "Watch an ad for 1 credit" only while it is true AND the
		-- client's own GetAdAvailabilityNowAsync answers IsAvailable.
		readyAttribute = "AdRewardReady",
		-- One DataStore row per player { day, purchaseId, granted } so the daily limit holds across servers and a
		-- redelivered receipt never pays twice. Studio uses its own store.
		store = "AdRewards",
		studioStore = "AdRewards_Studio",
		keyPrefix = "ad_",
		reason = "rewardedAd", -- CreditsService.grant reason (the log)
		-- What the player reads. Plain words.
		messages = {
			off = "Watching ads for credits isn't available right now.",
			comingSoon = "Coming soon!",
			loading = "Your save is still loading. Try again in a moment.",
			claimed = "You've had today's free credit. Come back tomorrow for another.",
			busy = "Your ad is already playing.",
			notReady = "No ad is ready right now. Try again in a little while.",
			interrupted = "The ad stopped before the end, so there's no credit this time.",
			failed = "The ad couldn't play right now. Try again in a little while.",
			thanks = "Thanks for watching! Your credit is on its way.",
			granted = "+%d Design Credit from the ad. Thanks for watching!", -- the credits
		},
	},

	productIds = productIds,
}

return Ads
