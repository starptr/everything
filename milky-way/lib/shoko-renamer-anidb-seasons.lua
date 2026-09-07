-- LuaRenamer script: AniDB-native seasonal layout that plays well with sublarr.
-- Based on the bundled default.lua. One change from default: rewrite the final `subfolder` so each
-- franchise nests under its TMDB show (already linked in Shoko), while every cour keeps its own AniDB
-- title as the inner folder + filename. TMDB is used ONLY for the umbrella folder name -- it re-groups
-- the cours that AniDB splits into separate entries. Net effect: AniDB season names stay first-class
-- on disk, sublarr gets a unique commonpath per franchise (no cross-franchise "Blue Box" collapse),
-- and Shoko's own series grouping (AutoGroupSeries) is left untouched -- so Shokofin/Jellyfin are
-- unaffected. Series with no TMDB show link (e.g. movies) fall back to a flat AniDB-named folder.
--
-- FILENAME: Trash-Guides-style token set so the source basename is self-describing (this is what
-- Shokofin surfaces as the per-version identifier via VFS_UseSourceFileAsVersionIdentifier). Trash
-- puts the release group last; the one deviation is that it LEADS here (anime convention). Two Trash
-- tokens have no Shoko equivalent and are omitted: Custom Formats (Sonarr-only) and VideoDynamicRange
-- /HDR (LuaRenamer's Video type exposes no dynamic-range field in this build).

local maxnamelen = 90
local animelanguage = Language.English
local episodelanguage = Language.English
local spacechar = " "

-- Map ':' and friends to safe look-alikes (needed for SMB / Jellyfin; harmless on ext4/NFS).
-- Comment this out if you'd rather keep raw ':' in names on the Linux side.
replace_illegal_chars = true

local group = ""
-- Check if anidb and release group keys exist before trying to access them (they may be nil)
if file.anidb and file.anidb.releasegroup then
  group = "[" .. (file.anidb.releasegroup.shortname or file.anidb.releasegroup.name) .. "]"
end
local animename = anime:getname(animelanguage) or anime.preferredname

local episodename = ""
local engepname = episode:getname(Language.English) or ""
local episodenumber = ""
-- If the episode is not a complete movie then add an episode number/name
if anime.type ~= AnimeType.Movie or not engepname:find("^Complete Movie") then
  local fileversion = ""
  if (file.anidb and file.anidb.version > 1) then
    fileversion = "v" .. file.anidb.version
  end
  -- Padding is determined from the number of episodes of the same type in the anime (#tostring() gives the number of digits required, e.g. 10 eps -> 2 digits)
  -- Padding is at least 2 digits
  local epnumpadding = math.max(#tostring(anime.episodecounts[episode.type]), 2)
  episodenumber = episode_numbers(epnumpadding) .. fileversion

  -- If this file is associated with a single episode and the episode doesn't have a generic name, then add the episode name
  if #episodes == 1 and not engepname:find("^Episode") and not engepname:find("^OVA") then
    episodename = episode:getname(episodelanguage) or ""
  end
end

-- ===== Media-info tags (Trash-Guides token style; release group already leads via `group`). =====
local year = anime.airdate and ("(" .. anime.airdate.year .. ")") or ""

-- [Source-Resolution] e.g. [BluRay-1080p]  (Trash "Quality Full")
local quality = ""
do
  local p = {}
  if file.anidb and file.anidb.source and file.anidb.source ~= "" then p[#p + 1] = file.anidb.source end
  if file.media and file.media.video and file.media.video.res and file.media.video.res ~= "" then p[#p + 1] = file.media.video.res end
  if #p > 0 then quality = "[" .. table.concat(p, "-") .. "]" end
end

-- [AudioCodec Channels] e.g. [EAC3 5.1]  (primary audio track)
local audiotag = ""
if file.media and file.media.audio and #file.media.audio > 0 then
  local a = file.media.audio[1]
  local p = {}
  local acodec = (a.codec or ""):gsub("^A_", "")   -- strip Matroska track-type prefix (A_EAC3 -> EAC3)
  if acodec ~= "" then p[#p + 1] = acodec end
  if a.channels then p[#p + 1] = tostring(a.channels) end
  if #p > 0 then audiotag = "[" .. table.concat(p, " ") .. "]" end
end

-- [Lang] per dub language, e.g. [JA] or [JA][EN]. More than two dub languages collapse to a single
-- [MULTI-AUDIO] so a 7-dub release doesn't blow the filename out (AniDB's dub list is the source --
-- more accurate than the MediaInfo stream tags). Keyed/looked-up by tostring(l) so it never references
-- a possibly-undefined Language.<X> symbol, and an unmapped language falls back to its full name.
local langcodes = {
  Japanese = 'JA', English = 'EN', Chinese = 'ZH', Korean = 'KO', German = 'DE',
  Spanish = 'ES', French = 'FR', Italian = 'IT', Portuguese = 'PT', Russian = 'RU',
}
local langtag = ""
do
  local list = {}
  if file.anidb then
    list = file.anidb.media.dublanguages
  elseif file.media then
    for _, a in ipairs(file.media.audio) do list[#list + 1] = a.language end
  end
  local codes, seen = {}, {}
  for _, l in ipairs(list) do
    local key = tostring(l)
    if key ~= "" and key ~= "Unknown" and not seen[key] then
      seen[key] = true
      codes[#codes + 1] = langcodes[key] or key
    end
  end
  if #codes > 2 then
    langtag = "[MULTI-AUDIO]"
  else
    for _, c in ipairs(codes) do langtag = langtag .. "[" .. c .. "]" end
  end
end

-- [VideoCodec BitDepth] e.g. [x265 10bit]  (bit depth hidden when 8-bit)
local videotag = ""
if file.media and file.media.video then
  local v = file.media.video
  local s = (v.codec or ""):gsub("^V_", "")        -- defensive: strip Matroska track-type prefix
  if v.bitdepth and v.bitdepth ~= 8 then s = (s ~= "" and s .. " " or "") .. v.bitdepth .. "bit" end
  if s ~= "" then videotag = "[" .. s .. "]" end
end

-- Censorship tag (only meaningful for age-restricted anime) -- kept from default.
local centag = ""
if file.anidb and anime.restricted then
  centag = file.anidb.censored and "[CEN]" or "[UNCEN]"
end

-- CRC -- kept from default: the ultimate version discriminator.
local crchash = ""
if file.hashes.crc then crchash = "[" .. file.hashes.crc .. "]" end

-- Assemble: [Group] Title (Year) - EpNum - EpTitle [Quality][Audio][Langs][Video][cen][crc]
-- Trash "CleanTitleWithoutYear": strip a trailing " (YYYY)" the AniDB title may already carry
-- (e.g. "Link Click (2026)") so appending the airdate year below doesn't double it.
local titlenoyear = animename:gsub(" %(%d%d%d%d%)$", "")
local core = titlenoyear:truncate(maxnamelen)
if year ~= "" then core = core .. " " .. year end
if episodenumber ~= "" then core = core .. " - " .. episodenumber end
if episodename ~= "" then core = core .. " - " .. episodename:truncate(maxnamelen) end

filename = table.concat({
  group, core, quality, audiotag, langtag, videotag, centag, crchash,
}, " "):cleanspaces(spacechar)

-- Seasonal layout: franchise umbrella = TMDB show (re-groups AniDB's split cours), inner folder + the
-- filename = AniDB cour name (stays first-class). Gives sublarr ONE commonpath per franchise.
-- Latin-script guard: [\194-\244] = UTF-8 lead bytes for any non-ASCII/CJK char. A few specials are
-- Japanese-only TMDB entries; for those we leave franchise nil and fall back to a flat English AniDB
-- folder rather than a Japanese umbrella. getname(English) is unreliable for TMDB shows here.
local function latin(s) return s and not s:find("[\194-\244]") end
local franchise = nil
if tmdb and tmdb.shows then
  -- Prefer a show whose name is a PROPER PREFIX of the AniDB name -- i.e. the parent franchise. A
  -- tie-in like "…- Stairway to Adulthood" links to BOTH its own self-titled spin-off show (listed
  -- first) AND the parent Kaguya show; picking shows[1] blindly buried it flat as a root sibling.
  for _, s in ipairs(tmdb.shows) do
    local nm = s.preferredname
    if latin(nm) and nm ~= animename and animename:sub(1, #nm) == nm then franchise = nm; break end
  end
  -- Otherwise the first Latin-script show (the normal cour case: its name == the umbrella).
  if not franchise and #tmdb.shows > 0 and latin(tmdb.shows[1].preferredname) then
    franchise = tmdb.shows[1].preferredname
  end
end
-- No TMDB show at all (e.g. a tie-in MOVIE links only to a TMDB movie): if the AniDB name carries a
-- "<Franchise> -…" separator, nest under that franchise prefix so the movie sits INSIDE its umbrella
-- instead of as a root sibling that drags the whole franchise's commonpath up to the library root
-- (which is what sublarr then keys the series on -> a giant catch-all row). e.g. "Fruits Basket
-- -prelude-" -> "Fruits Basket"; "Kaguya-sama: Love Is War - The First Kiss…" -> "Kaguya-sama: Love Is War".
if not franchise then
  local sep = animename:find(" %-")
  if sep and sep > 1 then franchise = animename:sub(1, sep - 1) end
end
if franchise and franchise ~= animename then
  subfolder = { franchise, animename }            -- cour nests under its franchise, keeping its AniDB name
elseif franchise then
  subfolder = { franchise }                        -- cour title == show title: sits in the franchise folder
else
  subfolder = { animename }                        -- no TMDB show link (e.g. movie): flat AniDB folder
end

-- AniDB credit/trailer/parody entries (C = creditless OP/ED, T = trailer, P = parody/promo) are not
-- real episodes. Left in the cour folder, sublarr scans them as series files and -- because each is a
-- 1-file group whose commonpath is the cour folder -- a credit file's group can OVERWRITE the series'
-- display title (last upsert on the same folder_path wins), e.g. "… C03 Ending". Tuck them in an
-- Extras subfolder so they get their own out-of-the-way row and never clobber the main series.
-- (Do NOT include 'S'/'O' -- Specials/Others are real content, and the tie-in movies use 'O'.)
if episode and (episode.prefix == 'C' or episode.prefix == 'T' or episode.prefix == 'P') then
  if type(subfolder) == 'table' then table.insert(subfolder, 'Extras')
  else subfolder = { subfolder, 'Extras' } end
end
