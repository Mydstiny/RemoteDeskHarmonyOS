/** GENERATED FILE. Edit totp_brand_manifest.json and rerun the generator. */

export const TOTP_OFFICIAL_BRAND_SOURCE_SHA256: string = "82dd94d4a82a910e97b50e8a72227eb78cec299035fb99681fa6c829fc39bc91";

export interface TotpOfficialBrandEntry {
  brandId: string;
  displayName: string;
  aliases: string[];
  exactDomains: string[];
  localAsset: string;
  assetBytes: number;
  sha256: string;
  sourceType: 'official' | 'svglogos-catalog';
  brandColor: string;
}

export const TOTP_OFFICIAL_BRANDS: TotpOfficialBrandEntry[] = [
  {
    brandId: "google",
    displayName: "Google",
    aliases: ["google", "gmail", "google workspace", "google authenticator"],
    exactDomains: ["google.com", "gmail.com"],
    localAsset: "totp-brands/official/google.svg",
    assetBytes: 1344,
    sha256: "5bcaca44adebed6dda51fb7fbe6bb4d59c6438db591736fbfc3f9bfa425010bb",
    sourceType: "official",
    brandColor: "#4285F4"
  },
  {
    brandId: "x",
    displayName: "X",
    aliases: ["x", "twitter"],
    exactDomains: ["x.com", "twitter.com"],
    localAsset: "totp-brands/official/x.svg",
    assetBytes: 733,
    sha256: "2c89d657423e4668d12422488ee4e624b5f2bfe0dec5ae6d71f2f9470306f4db",
    sourceType: "official",
    brandColor: "#000000"
  },
  {
    brandId: "microsoft",
    displayName: "Microsoft",
    aliases: ["microsoft", "microsoft 365", "office 365", "outlook", "microsoft authenticator"],
    exactDomains: ["microsoft.com", "microsoftonline.com", "office.com", "office365.com", "outlook.com", "hotmail.com", "live.com"],
    localAsset: "totp-brands/official/microsoft.svg",
    assetBytes: 689,
    sha256: "0a70bb4ba26d5cf9bbd377a82c7a14c845cda823032547505f7f8baa9921740a",
    sourceType: "official",
    brandColor: "#5E5E5E"
  },
  {
    brandId: "linkedin",
    displayName: "LinkedIn",
    aliases: ["linkedin"],
    exactDomains: ["linkedin.com"],
    localAsset: "totp-brands/official/linkedin.svg",
    assetBytes: 1628,
    sha256: "e14ad9c44fe2388edfd215688583a79a1c27148116191b5e73a85d96b5edc673",
    sourceType: "official",
    brandColor: "#0A66C2"
  },
  {
    brandId: "rustdesk",
    displayName: "RustDesk",
    aliases: ["rustdesk", "rust desk", "rustdesk server"],
    exactDomains: ["rustdesk.com"],
    localAsset: "totp-brands/official/rustdesk.svg",
    assetBytes: 1352,
    sha256: "9d090a828bd2c8dba6f94252b4f96feea495ebc0681e366a99edc3c119b69a9b",
    sourceType: "official",
    brandColor: "#024EFF"
  },
  {
    brandId: "baota",
    displayName: "宝塔面板",
    aliases: ["宝塔", "宝塔面板", "宝塔 Linux 面板", "baota", "baota panel", "bt panel"],
    exactDomains: ["bt.cn"],
    localAsset: "totp-brands/official/baota.png",
    assetBytes: 1523,
    sha256: "511d71c825d63c9ecc33cee1e9876baedcf191b87fa4346643c1c2dfd040380b",
    sourceType: "official",
    brandColor: "#20A53A"
  },
  {
    brandId: "aws",
    displayName: "AWS",
    aliases: ["AWS", "Amazon Web Services", "Amazon AWS"],
    exactDomains: ["aws.amazon.com", "amazonaws.com"],
    localAsset: "totp-brands/catalog/aws.svg",
    assetBytes: 8235,
    sha256: "3a4720542e42a50cd738f6150f54efe8161c1aaed601af07ea4ad3a19d5f18c2",
    sourceType: "svglogos-catalog",
    brandColor: "#232F3E"
  },
  {
    brandId: "slack",
    displayName: "Slack",
    aliases: ["Slack", "Slack Technologies"],
    exactDomains: ["slack.com"],
    localAsset: "totp-brands/catalog/slack.svg",
    assetBytes: 2807,
    sha256: "cf3c36c4ec98189ac7195410f0b93839b33527a71d023b69960d95129a4532a2",
    sourceType: "svglogos-catalog",
    brandColor: "#4A154B"
  },
  {
    brandId: "adobe",
    displayName: "Adobe",
    aliases: ["Adobe", "Adobe Creative Cloud"],
    exactDomains: ["adobe.com"],
    localAsset: "totp-brands/catalog/adobe.svg",
    assetBytes: 576,
    sha256: "443e0339c7ef407c61b77d01f10a2b884b658dcbb1dda1db34521b5b6998c1ae",
    sourceType: "svglogos-catalog",
    brandColor: "#FF0000"
  },
  {
    brandId: "openai",
    displayName: "OpenAI",
    aliases: ["OpenAI", "ChatGPT"],
    exactDomains: ["openai.com", "chatgpt.com"],
    localAsset: "totp-brands/catalog/openai.svg",
    assetBytes: 3741,
    sha256: "9c4a3baf62dc6950e9357302080d33120005e866fbc101ca3fe3cf7cb4ed54c4",
    sourceType: "svglogos-catalog",
    brandColor: "#000000"
  },
  {
    brandId: "anthropic",
    displayName: "Anthropic",
    aliases: ["Anthropic"],
    exactDomains: ["anthropic.com"],
    localAsset: "totp-brands/catalog/anthropic.svg",
    assetBytes: 1340,
    sha256: "164aa36f738c62dc7d886420295f5f2eac18f23f1e2541340c49fd999f0cbdc1",
    sourceType: "svglogos-catalog",
    brandColor: "#D97757"
  },
  {
    brandId: "claude",
    displayName: "Claude",
    aliases: ["Claude", "Claude AI"],
    exactDomains: ["claude.ai"],
    localAsset: "totp-brands/catalog/claude.svg",
    assetBytes: 3897,
    sha256: "9821277268934ad3e1565cc651adb849ffc51b6cd88b3dbdac7097652bef5677",
    sourceType: "svglogos-catalog",
    brandColor: "#D97757"
  },
  {
    brandId: "oracle",
    displayName: "Oracle",
    aliases: ["Oracle"],
    exactDomains: ["oracle.com"],
    localAsset: "totp-brands/catalog/oracle.svg",
    assetBytes: 3256,
    sha256: "41137d264838d7f57e589ea7490669b177c992a0638ee2e2b0000622927344ef",
    sourceType: "svglogos-catalog",
    brandColor: "#C74634"
  },
  {
    brandId: "ibm",
    displayName: "IBM",
    aliases: ["IBM"],
    exactDomains: ["ibm.com"],
    localAsset: "totp-brands/catalog/ibm.svg",
    assetBytes: 4777,
    sha256: "a3aa393edc0fa65cae70a21989f361af2a3d0adc418a73a096f5b54a87d1cf7d",
    sourceType: "svglogos-catalog",
    brandColor: "#0F62FE"
  },
  {
    brandId: "salesforce",
    displayName: "Salesforce",
    aliases: ["Salesforce"],
    exactDomains: ["salesforce.com"],
    localAsset: "totp-brands/catalog/salesforce.svg",
    assetBytes: 18293,
    sha256: "01cb0a0dc789097a443b827a36a624b69199a3a28f909e8a850f905926b5ae18",
    sourceType: "svglogos-catalog",
    brandColor: "#00A1E0"
  },
  {
    brandId: "twilio",
    displayName: "Twilio",
    aliases: ["Twilio"],
    exactDomains: ["twilio.com"],
    localAsset: "totp-brands/catalog/twilio.svg",
    assetBytes: 1499,
    sha256: "95c1f1aad8d5c0c9e797fa12d809d654313d4436e6f542da59c9dad1dd92bf5c",
    sourceType: "svglogos-catalog",
    brandColor: "#F22F46"
  },
  {
    brandId: "android",
    displayName: "Android",
    aliases: ["Android"],
    exactDomains: ["android.com"],
    localAsset: "totp-brands/catalog/android.svg",
    assetBytes: 4903,
    sha256: "7a0c7b491fa7370376aa556b07f88f0c927b24e6bded4e51850a3f600aeb633d",
    sourceType: "svglogos-catalog",
    brandColor: "#3DDC84"
  },
  {
    brandId: "microsoftazure",
    displayName: "Microsoft Azure",
    aliases: ["Microsoft Azure", "Azure"],
    exactDomains: ["azure.com"],
    localAsset: "totp-brands/catalog/microsoftazure.svg",
    assetBytes: 3408,
    sha256: "7ccf0a9829dbea0fd6e86262591c23b7ea9a5fa7ad8c7e4e0d431f57e9d02518",
    sourceType: "svglogos-catalog",
    brandColor: "#0078D4"
  },
  {
    brandId: "microsoftteams",
    displayName: "Microsoft Teams",
    aliases: ["Microsoft Teams", "Teams"],
    exactDomains: ["teams.microsoft.com"],
    localAsset: "totp-brands/catalog/microsoftteams.svg",
    assetBytes: 5580,
    sha256: "05a9700b771f7cd8932f8baefd5c21b41ea80a288374dd749635385efd141c37",
    sourceType: "svglogos-catalog",
    brandColor: "#6264A7"
  },
  {
    brandId: "microsoftedge",
    displayName: "Microsoft Edge",
    aliases: ["Microsoft Edge", "Edge"],
    exactDomains: ["microsoftedge.com"],
    localAsset: "totp-brands/catalog/microsoftedge.svg",
    assetBytes: 4790,
    sha256: "8892bd5708c6789dbd9135d118e4c3b06adb9f9606506081abb863d67e0b7b47",
    sourceType: "svglogos-catalog",
    brandColor: "#0C59F2"
  },
  {
    brandId: "deepseek",
    displayName: "DeepSeek",
    aliases: ["DeepSeek", "深度求索"],
    exactDomains: ["deepseek.com"],
    localAsset: "totp-brands/catalog/deepseek.svg",
    assetBytes: 5204,
    sha256: "92e9f6f67a934b7b872b147fd9a0de098a4c2eef71aee1684c17626002033373",
    sourceType: "svglogos-catalog",
    brandColor: "#4D6BFE"
  },
  {
    brandId: "unionpay",
    displayName: "UnionPay",
    aliases: ["UnionPay", "中国银联", "银联"],
    exactDomains: ["unionpay.com", "unionpay.com.cn"],
    localAsset: "totp-brands/catalog/unionpay.svg",
    assetBytes: 17610,
    sha256: "160c25ea9849cc1744251cd24cfc12b644da583160fd11a5f61c2fa7bdb92dce",
    sourceType: "svglogos-catalog",
    brandColor: "#0052A4"
  },
  {
    brandId: "firebase",
    displayName: "Firebase",
    aliases: ["Firebase"],
    exactDomains: ["firebase.google.com"],
    localAsset: "totp-brands/catalog/firebase.svg",
    assetBytes: 2040,
    sha256: "e27c7caef5cbab0197868dd16d650ba954b23ae2bc993cd3d1de6b65584d50b0",
    sourceType: "svglogos-catalog",
    brandColor: "#FFCA28"
  },
  {
    brandId: "supabase",
    displayName: "Supabase",
    aliases: ["Supabase"],
    exactDomains: ["supabase.com"],
    localAsset: "totp-brands/catalog/supabase.svg",
    assetBytes: 1713,
    sha256: "0c06fdc60b232345495993498f22da0d6261c517dcc9332415b90a4f78d58fa0",
    sourceType: "svglogos-catalog",
    brandColor: "#3ECF8E"
  },
  {
    brandId: "hashicorp",
    displayName: "HashiCorp",
    aliases: ["HashiCorp"],
    exactDomains: ["hashicorp.com"],
    localAsset: "totp-brands/catalog/hashicorp.svg",
    assetBytes: 827,
    sha256: "49dfdf0777d826c709cfd17c75470ead97b1cc5af77bb1251e6860927f5d357d",
    sourceType: "svglogos-catalog",
    brandColor: "#5C2D91"
  },
  {
    brandId: "vmware",
    displayName: "VMware",
    aliases: ["VMware"],
    exactDomains: ["vmware.com"],
    localAsset: "totp-brands/catalog/vmware.svg",
    assetBytes: 6098,
    sha256: "458e127aa6efa34ad6a60462475add42a8baeaee39ca49325c93a3ede908ea47",
    sourceType: "svglogos-catalog",
    brandColor: "#607078"
  },
  {
    brandId: "snyk",
    displayName: "Snyk",
    aliases: ["Snyk"],
    exactDomains: ["snyk.io"],
    localAsset: "totp-brands/catalog/snyk.svg",
    assetBytes: 12050,
    sha256: "4ae8a9d23243e6fadbfdec9e6e404d0f0b72a35d5c55be582d6ec8830144e4cb",
    sourceType: "svglogos-catalog",
    brandColor: "#1E1E1E"
  },
  {
    brandId: "auth0",
    displayName: "Auth0",
    aliases: ["Auth0", "Auth0 by Okta"],
    exactDomains: ["auth0.com"],
    localAsset: "totp-brands/catalog/auth0.svg",
    assetBytes: 877,
    sha256: "85db290f5908edf2c9eadeade025ac05ece738ed183c25e583f404dd44b7ab89",
    sourceType: "svglogos-catalog",
    brandColor: "#EB5424"
  },
  {
    brandId: "zoho",
    displayName: "Zoho",
    aliases: ["Zoho", "Zoho Corporation"],
    exactDomains: ["zoho.com"],
    localAsset: "totp-brands/catalog/zoho.svg",
    assetBytes: 7903,
    sha256: "fd8f15d858ef358db65da7da90215eaa97b407456fcbf050f6d59f383825a93e",
    sourceType: "svglogos-catalog",
    brandColor: "#F15B2A"
  },
  {
    brandId: "zapier",
    displayName: "Zapier",
    aliases: ["Zapier"],
    exactDomains: ["zapier.com"],
    localAsset: "totp-brands/catalog/zapier.svg",
    assetBytes: 7318,
    sha256: "920ebb57c753e9c4cf5763966e4f06897641851de403667d33945a3313b3043c",
    sourceType: "svglogos-catalog",
    brandColor: "#FF4F00"
  }
];

export function findTotpOfficialBrand(issuerKey: string, domainKey: string): TotpOfficialBrandEntry | null {
  for (let index = 0; index < TOTP_OFFICIAL_BRANDS.length; index++) {
    const entry: TotpOfficialBrandEntry = TOTP_OFFICIAL_BRANDS[index];
    if (entry.aliases.indexOf(issuerKey) >= 0 || entry.exactDomains.indexOf(domainKey) >= 0) {
      return entry;
    }
  }
  return null;
}

export function totpOfficialBrandAssetPath(brandId: string): string {
  switch (brandId) {
    case "google": return "totp-brands/official/google.svg";
    case "x": return "totp-brands/official/x.svg";
    case "microsoft": return "totp-brands/official/microsoft.svg";
    case "linkedin": return "totp-brands/official/linkedin.svg";
    case "rustdesk": return "totp-brands/official/rustdesk.svg";
    case "baota": return "totp-brands/official/baota.png";
    case "aws": return "totp-brands/catalog/aws.svg";
    case "slack": return "totp-brands/catalog/slack.svg";
    case "adobe": return "totp-brands/catalog/adobe.svg";
    case "openai": return "totp-brands/catalog/openai.svg";
    case "anthropic": return "totp-brands/catalog/anthropic.svg";
    case "claude": return "totp-brands/catalog/claude.svg";
    case "oracle": return "totp-brands/catalog/oracle.svg";
    case "ibm": return "totp-brands/catalog/ibm.svg";
    case "salesforce": return "totp-brands/catalog/salesforce.svg";
    case "twilio": return "totp-brands/catalog/twilio.svg";
    case "android": return "totp-brands/catalog/android.svg";
    case "microsoftazure": return "totp-brands/catalog/microsoftazure.svg";
    case "microsoftteams": return "totp-brands/catalog/microsoftteams.svg";
    case "microsoftedge": return "totp-brands/catalog/microsoftedge.svg";
    case "deepseek": return "totp-brands/catalog/deepseek.svg";
    case "unionpay": return "totp-brands/catalog/unionpay.svg";
    case "firebase": return "totp-brands/catalog/firebase.svg";
    case "supabase": return "totp-brands/catalog/supabase.svg";
    case "hashicorp": return "totp-brands/catalog/hashicorp.svg";
    case "vmware": return "totp-brands/catalog/vmware.svg";
    case "snyk": return "totp-brands/catalog/snyk.svg";
    case "auth0": return "totp-brands/catalog/auth0.svg";
    case "zoho": return "totp-brands/catalog/zoho.svg";
    case "zapier": return "totp-brands/catalog/zapier.svg";
    default: return '';
  }
}

export function totpOfficialBrandAssetResource(brandId: string): Resource | null {
  switch (brandId) {
    case "google": return $rawfile("totp-brands/official/google.svg");
    case "x": return $rawfile("totp-brands/official/x.svg");
    case "microsoft": return $rawfile("totp-brands/official/microsoft.svg");
    case "linkedin": return $rawfile("totp-brands/official/linkedin.svg");
    case "rustdesk": return $rawfile("totp-brands/official/rustdesk.svg");
    case "baota": return $rawfile("totp-brands/official/baota.png");
    case "aws": return $rawfile("totp-brands/catalog/aws.svg");
    case "slack": return $rawfile("totp-brands/catalog/slack.svg");
    case "adobe": return $rawfile("totp-brands/catalog/adobe.svg");
    case "openai": return $rawfile("totp-brands/catalog/openai.svg");
    case "anthropic": return $rawfile("totp-brands/catalog/anthropic.svg");
    case "claude": return $rawfile("totp-brands/catalog/claude.svg");
    case "oracle": return $rawfile("totp-brands/catalog/oracle.svg");
    case "ibm": return $rawfile("totp-brands/catalog/ibm.svg");
    case "salesforce": return $rawfile("totp-brands/catalog/salesforce.svg");
    case "twilio": return $rawfile("totp-brands/catalog/twilio.svg");
    case "android": return $rawfile("totp-brands/catalog/android.svg");
    case "microsoftazure": return $rawfile("totp-brands/catalog/microsoftazure.svg");
    case "microsoftteams": return $rawfile("totp-brands/catalog/microsoftteams.svg");
    case "microsoftedge": return $rawfile("totp-brands/catalog/microsoftedge.svg");
    case "deepseek": return $rawfile("totp-brands/catalog/deepseek.svg");
    case "unionpay": return $rawfile("totp-brands/catalog/unionpay.svg");
    case "firebase": return $rawfile("totp-brands/catalog/firebase.svg");
    case "supabase": return $rawfile("totp-brands/catalog/supabase.svg");
    case "hashicorp": return $rawfile("totp-brands/catalog/hashicorp.svg");
    case "vmware": return $rawfile("totp-brands/catalog/vmware.svg");
    case "snyk": return $rawfile("totp-brands/catalog/snyk.svg");
    case "auth0": return $rawfile("totp-brands/catalog/auth0.svg");
    case "zoho": return $rawfile("totp-brands/catalog/zoho.svg");
    case "zapier": return $rawfile("totp-brands/catalog/zapier.svg");
    default: return null;
  }
}
