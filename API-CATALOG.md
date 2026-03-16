# API Catalog — Foundry

> **Purpose:** Curated, verified free APIs for use by the Ideator and Critic agents.
> **Rule:** Ideator must only use APIs from this catalog. No invented endpoints.
> **Source:** https://github.com/public-apis/public-apis (filtered for SaaS-relevant, free-tier, HTTPS)
> **Last verified:** 2026-03-17
> **Health check log:** `logs/api-health-YYYY-MM-DD.md` (updated weekly by api-health-check.sh)

---

## ⚠️ Already Used — Do Not Duplicate Core Mechanism

These APIs are already the backbone of existing factory projects. Fine to combine with others, but building another product where these are the *primary* value-add is a duplicate.

| API | Used By | What It Does |
|-----|---------|-------------|
| RandomUser | DemoSeed | Generates realistic user profiles |
| Agify.io | DemoSeed | Estimates age from first name |
| Genderize.io | DemoSeed | Estimates gender from first name |
| Nationalize.io | DemoSeed | Estimates nationality from first name |

---

## Category: Currency & Finance

| API | Base URL | Auth | Rate Limit | SaaS Potential |
|-----|---------|------|------------|----------------|
| Frankfurter | `https://api.frankfurter.app` | None | Unlimited | Exchange rates, time series, currency conversion — great for finance dashboards |
| Currency-api (fawazahmed0) | `https://cdn.jsdelivr.net/gh/fawazahmed0/currency-api@1/latest/currencies` | None | Unlimited | 150+ currencies, completely free CDN-hosted — most reliable free option |
| ExchangeRate-API | `https://v6.exchangerate-api.com/v6` | API Key | 1,500 req/month free | Conversion + historical rates with cleaner DX |
| Open Exchange Rates | `https://openexchangerates.org/api` | API Key | 1,000 req/month free | Hourly rates, 170+ currencies |
| VATComply | `https://api.vatcomply.com` | None | Unknown | VAT rates by country + EU validation + exchange rates |
| National Bank of Poland | `https://api.nbp.pl/api` | None | Unknown | PLN exchange rates with historical data |

---

## Category: Weather & Environment

| API | Base URL | Auth | Rate Limit | SaaS Potential |
|-----|---------|------|------------|----------------|
| Open-Meteo | `https://api.open-meteo.com/v1` | None | Unlimited (fair use) | **Best free weather API** — hourly/daily forecasts, no API key, global |
| Open-Meteo Historical | `https://archive-api.open-meteo.com/v1` | None | Unlimited (fair use) | Historical weather data going back to 1940 — great for analytics |
| WeatherAPI | `https://api.weatherapi.com/v1` | API Key | 1M req/month free | Weather + astronomy + air quality + alerts |
| US Weather (NOAA) | `https://api.weather.gov` | None | Unknown | Official US weather forecasts, alerts, station data |
| OpenUV | `https://api.openuv.io/api/v1` | API Key | 50 req/day free | Real-time UV index + forecast — niche but specific |
| RainViewer | `https://api.rainviewer.com/public/weather-maps.json` | None | Unknown | Radar/satellite weather map tiles |
| openSenseMap | `https://api.opensensemap.org` | None | Unknown | Crowdsourced environmental sensor data |

---

## Category: Geocoding & Location

| API | Base URL | Auth | Rate Limit | SaaS Potential |
|-----|---------|------|------------|----------------|
| Nominatim (OpenStreetMap) | `https://nominatim.openstreetmap.org` | None | 1 req/sec | Forward + reverse geocoding — unlimited but rate limited |
| OpenCage | `https://api.opencagedata.com/geocode/v1` | API Key | 2,500 req/day free | Forward + reverse geocoding with great DX |
| Geoapify | `https://api.geoapify.com/v1` | API Key | 3,000 req/day free | Geocoding + address autocomplete + routing |
| ipapi.co | `https://ipapi.co` | None | 1,000 req/day free | IP to location (country, city, lat/lng, timezone) |
| ip-api | `http://ip-api.com/json` | None | 45 req/min (HTTP only) | IP geolocation — HTTP only on free tier |
| geoPlugin | `https://ssl.geoplugin.net/json.gp` | None | Unknown | IP geolocation + nearest currency |
| REST Countries | `https://restcountries.com/v3.1` | None | Unknown | Country data — flags, currencies, languages, calling codes |
| Postcodes.io | `https://api.postcodes.io` | None | Unknown | UK postcode lookup + geolocation |
| Zippopotam.us | `https://api.zippopotam.us` | None | Unknown | ZIP/postal code to city/state/country |

---

## Category: Data Validation

| API | Base URL | Auth | Rate Limit | SaaS Potential |
|-----|---------|------|------------|----------------|
| Abstract Email Validation | `https://emailvalidation.abstractapi.com/v1` | API Key | 100 req/month free | Email deliverability, catch-all, disposable check |
| Mailboxlayer | `https://apilayer.net/api/check` | API Key | 100 req/month free | Email format + MX + SMTP check |
| Disify | `https://www.disify.com/api/email` | None | Unknown | Detect disposable/temporary email addresses |
| EVA (Email Validation) | `https://api.eva.pingutil.com/email` | None | Unknown | Email validation — free, no auth |
| Abstract Phone Validation | `https://phonevalidation.abstractapi.com/v1` | API Key | 100 req/month free | Phone number validation + carrier + line type |
| Numverify | `https://apilayer.net/api/validate` | API Key | 100 req/month free | International phone validation + carrier |
| VATComply VAT | `https://api.vatcomply.com/vat` | None | Unknown | EU VAT number validation |
| vatlayer | `https://apilayer.net/api/validate` | API Key | 100 req/month free | EU VAT number structure + existence check |
| Abstract IP Geolocation | `https://ipgeolocation.abstractapi.com/v1` | API Key | 100 req/month free | IP to location + security flags (VPN/proxy/tor) |

---

## Category: Test Data Generation

> **Note:** DemoSeed already covers the core "fake user profiles" space. Ideas here should find an adjacent angle — industry-specific data, developer tooling, specific data types.

| API | Base URL | Auth | Rate Limit | SaaS Potential |
|-----|---------|------|------------|----------------|
| FakerAPI | `https://fakerapi.it/api/v1` | None | Unknown | Generate fake persons, addresses, products, texts, companies |
| Random Data API | `https://random-data-api.com/api` | None | Unknown | Random banks, addresses, blood types, colors, commerce |
| FakeJSON | `https://app.fakejson.com/q` | API Key | 10,000 req/month free | Custom schema fake data generation |
| Mockaroo | `https://my.api.mockaroo.com/people.json` | API Key | 50 rows/req free | Upload schema, get typed test data (CSV/JSON/SQL) |
| Bacon Ipsum | `https://baconipsum.com/api` | None | Unknown | Placeholder text (meat-themed lorem ipsum) |
| RandomUser | `https://randomuser.me/api` | None | Unlimited | Random user profiles — **already used in DemoSeed** |

---

## Category: News & Media

| API | Base URL | Auth | Rate Limit | SaaS Potential |
|-----|---------|------|------------|----------------|
| NewsAPI | `https://newsapi.org/v2` | API Key | 100 req/day free (dev) | Headlines + search from 80,000+ sources |
| GNews | `https://gnews.io/api/v4` | API Key | 100 req/day free | News search + top headlines, 60+ languages |
| Currents API | `https://api.currentsapi.services/v1` | API Key | 600 req/month free | Latest news from blogs & forums |
| Mediastack | `https://api.mediastack.com/v1` | API Key | 100 req/month free | Live news, historical, source filtering |

---

## Category: Health & Fitness

| API | Base URL | Auth | Rate Limit | SaaS Potential |
|-----|---------|------|------------|----------------|
| Open Disease | `https://disease.sh/v3/covid-19` | None | Unknown | COVID-19, flu, monkeypox current case data worldwide |
| FoodData Central (USDA) | `https://api.nal.usda.gov/fdc/v1` | API Key | Free | Comprehensive nutrition database — 600k+ foods |
| Nutritionix | `https://trackapi.nutritionix.com/v2` | API Key | Free tier | Natural language → nutrition data ("2 slices of pizza") |
| Open Food Facts | `https://world.openfoodfacts.org/api/v0` | None | Unknown | Barcode → food nutrition data (crowdsourced) |
| Infermedica | `https://api.infermedica.com/v3` | API Key | Free tier | Symptom checker + triage + medical NLP |

---

## Category: Finance & Business Data

| API | Base URL | Auth | Rate Limit | SaaS Potential |
|-----|---------|------|------------|----------------|
| CoinGecko | `https://api.coingecko.com/api/v3` | None | 50 req/min free | Crypto prices, market cap, volume — most comprehensive free |
| Coinpaprika | `https://api.coinpaprika.com/v1` | None | Unknown | Crypto prices + ICO data + exchanges |
| Alpha Vantage | `https://www.alphavantage.co/query` | API Key | 5 req/min, 500 req/day free | Stocks, forex, crypto, technical indicators |
| Twelve Data | `https://api.twelvedata.com` | API Key | 8 req/min, 800 req/day free | Stocks, forex, ETF, crypto real-time + historical |
| Financial Modeling Prep | `https://financialmodelingprep.com/api/v3` | API Key | 250 req/day free | Financial statements, ratios, DCF, news |
| Companies House (UK) | `https://api.company-information.service.gov.uk` | API Key | Free | UK company data — directors, filings, addresses |

---

## Category: Jobs & Recruitment

| API | Base URL | Auth | Rate Limit | SaaS Potential |
|-----|---------|------|------------|----------------|
| Arbeitnow | `https://www.arbeitnow.com/api/job-board-api` | None | Unknown | European tech job board — remote + visa sponsorship filter |
| DevITjobs UK | `https://devitjobs.uk/api/jobsLight` | None | Unknown | UK dev jobs with tech stack filter |
| GraphQL Jobs | `https://api.graphql.jobs` | None | Unknown | GraphQL-based job board |
| USAJOBS | `https://data.usajobs.gov/api/search` | API Key | Free | US federal government jobs |
| Remotive | `https://remotive.com/api/remote-jobs` | None | Unknown | Remote job listings across categories |

---

## Category: Text, Language & NLP

| API | Base URL | Auth | Rate Limit | SaaS Potential |
|-----|---------|------|------------|----------------|
| LibreTranslate | `https://libretranslate.com` | None / API Key | Unknown | Open source translation — self-hostable, 17 languages |
| Detect Language | `https://ws.detectlanguage.com/0.2/detect` | API Key | 10,000 req/month free | Detect language of any text |
| MeaningCloud Sentiment | `https://api.meaningcloud.com/sentiment-2.1` | API Key | 40,000 units/month free | Multilingual sentiment + subjectivity analysis |
| Perspective API (Google) | `https://commentanalyzer.googleapis.com/v1alpha1` | API Key | Free | Detect toxic, obscene, spam content |
| PoetryDB | `https://poetrydb.org` | None | Unknown | Classic poetry search by author, title, lines |

---

## Category: Security & Trust

| API | Base URL | Auth | Rate Limit | SaaS Potential |
|-----|---------|------|------------|----------------|
| HaveIBeenPwned | `https://haveibeenpwned.com/api/v3` | API Key | 10 req/min free | Check if email/password exposed in breaches |
| EmailRep | `https://emailrep.io` | None (or API Key for higher) | 100 req/day free | Email threat score — spam, phishing, reputation |
| FraudLabs Pro | `https://api.fraudlabspro.com/v1` | API Key | 500 req/month free | Fraud detection for orders — IP, email, billing |
| Shodan | `https://api.shodan.io` | API Key | Free tier limited | Internet-connected device search + exposure check |

---

## Category: Government & Open Data

| API | Base URL | Auth | Rate Limit | SaaS Potential |
|-----|---------|------|------------|----------------|
| Data USA | `https://datausa.io/api/data` | None | Unknown | US Census + BLS data — education, income, jobs by geography |
| Wikipedia (MediaWiki) | `https://en.wikipedia.org/w/api.php` | None | Unknown | Article summaries, search, page data |
| Wikidata | `https://www.wikidata.org/w/api.php` | None | Unknown | Structured knowledge base — entities, facts, relationships |
| Nobel Prize | `https://api.nobelprize.org/2.1` | None | Unknown | All Nobel prizes, laureates, categories since 1901 |
| OpenSanctions | `https://api.opensanctions.org` | None | Unknown | Sanctions lists, PEP data, financial crime watchlists |
| US Census Bureau | `https://api.census.gov/data` | API Key | Free | US demographic, economic, geographic census data |

---

## Category: Calendar & Holidays

| API | Base URL | Auth | Rate Limit | SaaS Potential |
|-----|---------|------|------------|----------------|
| Nager.Date | `https://date.nager.at/api/v3` | None | Unknown | Public holidays for 90+ countries — best free option |
| Calendarific | `https://calendarific.com/api/v2` | API Key | 50 req/month free | 230+ countries, religious + national holidays |
| Abstract Holidays | `https://holidays.abstractapi.com/v1` | API Key | 100 req/month free | National + religious holidays by country + year |
| Namedays Calendar | `https://nameday.abalin.net/api/V1` | None | Unknown | Nameday data — Czech, Slovak, Polish, Hungarian, etc. |

---

## Category: Transportation & Routing

| API | Base URL | Auth | Rate Limit | SaaS Potential |
|-----|---------|------|------------|----------------|
| GraphHopper | `https://graphhopper.com/api/1` | API Key | 2,500 req/day free | A-to-B routing, distance matrix, geocoding |
| Open Charge Map | `https://api.openchargemap.io/v3` | API Key | Free | EV charging station locations worldwide |
| Transport.rest | `https://v6.db.transport.rest` | None | Unknown | European public transit — Deutsche Bahn + more |
| BC Ferries | `https://www.bcferriesapi.ca/api` | None | Unknown | BC Ferries sailing schedules + capacity |
| AviationStack | `https://api.aviationstack.com/v1` | API Key | 100 req/month free | Real-time flight status + schedules |

---

## Category: Development & Testing Tools

| API | Base URL | Auth | Rate Limit | SaaS Potential |
|-----|---------|------|------------|----------------|
| GitHub | `https://api.github.com` | OAuth / Token | 60 req/hr anon, 5000 auth | Repository, user, PR, issue data — huge SaaS potential |
| JSONbin.io | `https://api.jsonbin.io/v3` | API Key | 1 req/min free | Free JSON storage — great for prototype backends |
| Httpbin | `https://httpbin.org` | None | Unknown | HTTP method testing, inspection, debugging |
| ReqRes | `https://reqres.in/api` | None | Unknown | Hosted test REST API — user CRUD mock data |
| Beeceptor | `https://beeceptor.com` | None | Unknown | Create mock REST API endpoint in seconds |

---

## Category: Books & Knowledge

| API | Base URL | Auth | Rate Limit | SaaS Potential |
|-----|---------|------|------------|----------------|
| Gutendex (Project Gutenberg) | `https://gutendex.com/books` | None | Unknown | 70,000+ free ebooks — search by author, genre, language |
| Open Library | `https://openlibrary.org/api` | None | Unknown | Book search, covers, author data — 20M+ books |
| Google Books | `https://www.googleapis.com/books/v1` | API Key | Free (with limits) | Book search, preview links, metadata |

---

## Category: Food & Drink

| API | Base URL | Auth | Rate Limit | SaaS Potential |
|-----|---------|------|------------|----------------|
| TheMealDB | `https://www.themealdb.com/api/json/v1/1` | None | Unknown | Recipes + ingredients + instructions + images |
| Open Food Facts | `https://world.openfoodfacts.org/api/v0` | None | Unknown | Barcode scan → full nutrition + ingredients |
| The Cocktail DB | `https://www.thecocktaildb.com/api/json/v1/1` | None | Unknown | Cocktail recipes, ingredients, glass types |
| Tasty (Rapidapi) | Via RapidAPI | API Key | 500 req/month free tier | Recipes from BuzzFeed Tasty |

---

## Category: Science & Space

| API | Base URL | Auth | Rate Limit | SaaS Potential |
|-----|---------|------|------------|----------------|
| NASA | `https://api.nasa.gov` | API Key | 1,000 req/day free | APOD, Mars photos, asteroid data, Earth imagery |
| Open Notify (ISS) | `http://api.open-notify.org` | None | Unknown | ISS current location + people in space (HTTP only) |
| Newton (Math) | `https://newton.vercel.app/api/v2` | None | Unknown | Advanced math operations — simplify, derive, integrate |
| Numbers API | `http://numbersapi.com` | None | Unknown | Interesting facts about numbers, dates, math |

---

## Category: Sports & Fitness

| API | Base URL | Auth | Rate Limit | SaaS Potential |
|-----|---------|------|------------|----------------|
| TheSportsDB | `https://www.thesportsdb.com/api/v1/json/3` | None (free key = "3") | Unknown | Sports, teams, players, events, leagues |
| NBA Data (unofficial) | `https://data.nba.net/prod/v1` | None | Unknown | NBA game scores, stats, schedules |
| balldontlie | `https://www.balldontlie.io/api/v1` | None | 60 req/min | NBA player stats, game scores |
| OpenLigaDB | `https://api.openligadb.de` | None | Unknown | German football league data |

---

## Category: Demographics & Identity

| API | Base URL | Auth | Rate Limit | SaaS Potential |
|-----|---------|------|------------|----------------|
| Agify.io | `https://api.agify.io` | None | 1,000 req/day free | Predict age from first name |
| Genderize.io | `https://api.genderize.io` | None | 1,000 req/day free | Predict gender from first name |
| Nationalize.io | `https://api.nationalize.io` | None | 1,000 req/day free | Predict nationality from first name |
| RandomUser | `https://randomuser.me/api` | None | Unlimited | Random user profiles (photos, addresses, contact info) |

---

## Category: URL & Link Tools

| API | Base URL | Auth | Rate Limit | SaaS Potential |
|-----|---------|------|------------|----------------|
| CleanURI | `https://cleanuri.com/api/v1/shorten` | None | Unknown | Free URL shortener |
| Kutt | `https://kutt.it/api/v2` | API Key | Free tier | Modern URL shortener + analytics |
| GoTiny | `https://api.gotiny.cc` | None | Unknown | Lightweight URL shortener |
| shrtcode | `https://shrtco.de/api/v2` | None | Unknown | Multi-domain URL shortening |

---

## Category: Social & Communication

| API | Base URL | Auth | Rate Limit | SaaS Potential |
|-----|---------|------|------------|----------------|
| Discord (Bot API) | `https://discord.com/api/v10` | Bot Token | Rate limited per endpoint | Read/send messages, manage servers |
| Reddit | `https://www.reddit.com/dev/api` | OAuth | 60 req/min | Posts, comments, subreddit data |
| Mastodon | `https://mastodon.social/api/v1` | OAuth | Unknown | Federated social network |

---

## Tips for Combining APIs (Emergent Value)

These combinations create products worth more than any single API:

| Combination | Potential Product |
|-------------|------------------|
| Open-Meteo + OpenCage | Weather dashboard with location search |
| NewsAPI + MeaningCloud Sentiment | News sentiment tracker for brands/topics |
| Alpha Vantage + Frankfurter | Multi-currency portfolio tracker |
| FoodData Central + Open Food Facts | Barcode scan → full nutrition breakdown |
| Nominatim + Nager.Date + Open-Meteo | "Is today a good day to work remotely?" (location-aware holiday + weather) |
| GitHub + Alpha Vantage | Developer portfolio valuation (commits + stock of employer) |
| HaveIBeenPwned + EmailRep | Email security audit tool for businesses |
| Arbeitnow + ipapi.co | Salary & jobs by location intelligence |
| CoinGecko + Frankfurter | Crypto in any local currency converter |
| Open Disease + REST Countries | Country-by-country health metrics dashboard |
