const brave = require("./providers/brave");
const custom = require("./providers/custom");
const google = require("./providers/google");
const serper = require("./providers/serper");
const serpapi = require("./providers/serpapi");
const tavily = require("./providers/tavily");

const providers = [serper, serpapi, google, tavily, brave, custom];

module.exports = {
  providers,
};
