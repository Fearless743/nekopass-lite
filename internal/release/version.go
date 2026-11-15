package release

// Version is set at build time with -ldflags "-X .../internal/release.Version=vX.Y.Z".
var Version = "dev"

const Repository = "fearless743/nekopass-lite"
const DownloadBase = "https://github.com/" + Repository + "/releases/download"
const LatestBase = "https://github.com/" + Repository + "/releases/latest/download"
