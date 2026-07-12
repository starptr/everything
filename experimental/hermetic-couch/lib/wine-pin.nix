# Single source of truth for the pinned frankea/Whisky wine bundle, shared by the wine
# runner's launch env AND the provisioning tool so they can't drift. Bump here to move
# the whole lower Windows-game stack (wine + its builtin ABI-matched DXMT) at once.
{
  version = "3.1.1";
  url = "https://github.com/frankea/Whisky/releases/download/v3.1.1/Libraries.tar.gz";
  hash = "sha256-AfOhtDuYBl/iDFKcECO2HdeabSrZO7pgQIZfZGSBzPM=";
}
