local net = require("@lune/net")
local serde = require("@lune/serde")
local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local task = require("@lune/task")

type CatalogQuery = { taxonomy: string }
type CatalogItem = {
	id: number,
	name: string,
	description: string,
	itemRestrictions: { "Limited" | "LimitedUnique" },
	favoriteCount: number,
	isOffSale: boolean,
	price: number,
	lowestPrice: number,
	lowestResalePrice: number,
	totalQuantity: number,
	hasResellers: boolean,

	productId: number,
	collectibleItemId: string,
}

-- GET https://catalog.roblox.com/v1/search/navigation-menu-items
local CLASSIC_HEAD_TAXONOMY = "1JiaNPKxcc5RL2X6b4VQwv"
local CLASSIC_FACE_TAXONOMY = "9atv5s8UMicJWBZXYMTjWH"

local CLASSIC_HEAD_DIR = "classic-heads"
local CLASSIC_FACE_DIR = "classic-faces"

local RETRY_DELAY = 5

local function searchCatalogItems(query: CatalogQuery & { cursor: string }): ({ CatalogItem }, string?)
	local url = "https://catalog.roblox.com/v2/search/items/details"
	url ..= `?taxonomy={query.taxonomy}`
	url ..= "&includeNotForSale=true"
	url ..= "&limit=120"
	url ..= `&cursor={query.cursor}`

	local response = net.request(url)

	if not response.ok then
		print(`Failed to query catalog items: {response.statusCode} {response.statusMessage}`)
		task.wait(RETRY_DELAY)
		return searchCatalogItems(query)
	end

	local body = serde.decode("json", response.body)
	return body.data, body.nextPageCursor
end

local function forEachCatalogItem(query: CatalogQuery, callback: (item: CatalogItem) -> ())
	local cursor: string? = ""
	while cursor do
		local items, nextCursor = searchCatalogItems({
			taxonomy = query.taxonomy,
			cursor = cursor,
		})
		cursor = nextCursor

		for _, item in items do
			callback(item)
		end
	end
end

local function getAssetLink(assetId: number): string?
	local response = net.request(`https://assetdelivery.roblox.com/v2/assetId/{assetId}`)

	if not response.ok then
		error(`Failed to resolve link for asset {assetId}: {response.statusCode} {response.statusMessage}`)
	end

	local body = serde.decode("json", response.body)
	if body.errors then
		return nil
	end
	return body.locations[1].location
end

local function downloadAsset(assetId: number): string?
	local assetLink = getAssetLink(assetId)
	if not assetLink then
		return nil
	end

	local response = net.request(assetLink)

	if not response.ok then
		print(`Failed to download asset {assetId}: {response.statusCode} {response.statusMessage}`)
		task.wait(RETRY_DELAY)
		return downloadAsset(assetId)
	end

	return response.body
end

local function extractAssetId(catalogAssetId: number): number?
	local catalogAsset = downloadAsset(catalogAssetId)
	if not catalogAsset then
		return nil
	end

	local instance = roblox.deserializeModel(catalogAsset)[1] :: any
	local contentId = if instance:IsA("Decal") then instance.TextureContent.Uri else nil

	if not contentId then
		return nil
	end

	local rawAssetId = string.match(contentId, "%d+$")
	local assetId = tonumber(rawAssetId)
	return assetId
end

if not fs.isDir(CLASSIC_FACE_DIR) then
	fs.writeDir(CLASSIC_FACE_DIR)
end
if not fs.isDir(CLASSIC_HEAD_DIR) then
	fs.writeDir(CLASSIC_HEAD_DIR)
end

local classicFaces = {}

forEachCatalogItem({ taxonomy = CLASSIC_FACE_TAXONOMY }, function(item)
	table.insert(classicFaces, {
		id = item.id,
		name = item.name,
		description = item.description,
		itemRestrictions = item.itemRestrictions,
		favoriteCount = item.favoriteCount,
		isOffSale = item.isOffSale,
		price = item.price,
		lowestPrice = item.lowestPrice,
		lowestResalePrice = item.lowestResalePrice,
		totalQuantity = item.totalQuantity,
		hasResellers = item.hasResellers,

		productId = item.productId,
		collectibleItemId = item.collectibleItemId,
	})

	local path = `{CLASSIC_FACE_DIR}/{item.id}.png`
	if fs.isFile(path) then
		return
	end

	local assetId = extractAssetId(item.id)
	if not assetId then
		print(`Face {item.name} has no texture`)
		return
	end

	local texture = downloadAsset(assetId)
	if texture then
		fs.writeFile(path, texture)
	end
end)

fs.writeFile(`{CLASSIC_FACE_DIR}/data.json`, serde.encode("json", classicFaces, true))

local classicHeads = {}

forEachCatalogItem({ taxonomy = CLASSIC_HEAD_TAXONOMY }, function(item)
	table.insert(classicHeads, {
		id = item.id,
		name = item.name,
		description = item.description,
		isOffSale = item.isOffSale,
		favoriteCount = item.favoriteCount,
		price = item.price,
		productId = item.productId,
	})

	local path = `{CLASSIC_HEAD_DIR}/{item.id}.rbxm`
	if fs.isFile(path) then
		return
	end

	local asset = downloadAsset(item.id)
	if asset then
		fs.writeFile(path, asset)
	end
end)

fs.writeFile(`{CLASSIC_HEAD_DIR}/data.json`, serde.encode("json", classicHeads, true))
