const { SearchProviderManager } = require("./provider_manager");
const { providers } = require("./registry");

function createSearchProviderManager(options = {}) {
  return new SearchProviderManager({
    providers,
    ...options,
  });
}

module.exports = {
  createSearchProviderManager,
  providers,
  SearchProviderManager,
};
