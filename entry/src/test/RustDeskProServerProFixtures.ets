/**
 * Redacted RustDesk Server Pro contract fixtures.
 * Upstream shape is pinned to the source reviewed for this adapter; values
 * below are synthetic and must never be replaced with production credentials.
 */
export const RUSTDESK_PRO_UPSTREAM_COMMIT: string =
  '807e05ea9a7e298ed2deb438195faaafce19cdd2';

export interface RustDeskProFixtureUser {
  id: string
  name: string
  display_name: string
  email?: string
}

export interface RustDeskProLoginFixture {
  access_token?: string
  type?: string
  tfa_type?: string
  secret?: string
  user?: RustDeskProFixtureUser
  error?: string
  unsupportedFields?: string[]
  code?: string
  detail?: string
}

export interface RustDeskProAddressBookProfileFixture {
  guid: string
  name: string
  owner: string
  share_rule: string
}

export interface RustDeskProAddressBookProfilePageFixture {
  total: number
  current: number
  pageSize: number
  data: RustDeskProAddressBookProfileFixture[]
}

export interface RustDeskProAddressBookTagFixture {
  name: string
  color: number
}

export interface RustDeskProAddressBookPeerFixture {
  id: string
  membership_id?: string
  alias: string
  hostname: string
  platform: string
  note?: string
  tags: RustDeskProAddressBookTagFixture[]
}

export interface RustDeskProAddressBookPeerPageFixture {
  total: number
  current: number
  pageSize: number
  data: RustDeskProAddressBookPeerFixture[]
}

export interface RustDeskProLegacyPeerFixture {
  id: string
  alias: string
  hostname: string
  platform: string
  tags: string[]
  note: string
}

export interface RustDeskProLegacyDataFixture {
  tags: string[]
  peers: RustDeskProLegacyPeerFixture[]
}

export interface RustDeskProLegacyResponseFixture {
  data: string
}

export interface RustDeskProAddressBookErrorFixture {
  error: string
  code: string
  detail?: string
}

export const RUSTDESK_PRO_SUCCESS_RESPONSE: RustDeskProLoginFixture = {
  access_token: '<fixture-access-token>',
  user: { id: 'fixture-user', name: 'fixture-user', display_name: 'Fixture User' }
};

export const RUSTDESK_PRO_EMAIL_CHALLENGE_RESPONSE: RustDeskProLoginFixture = {
  type: 'email_check',
  tfa_type: 'email_check',
  secret: '<fixture-email-challenge-secret>',
  user: {
    id: 'fixture-user', name: 'fixture-user@example.test',
    display_name: 'Fixture User', email: 'fixture-user@example.test'
  }
};

export const RUSTDESK_PRO_TOTP_CHALLENGE_RESPONSE: RustDeskProLoginFixture = {
  type: 'email_check',
  tfa_type: 'tfa_check',
  secret: '<fixture-totp-challenge-secret>',
  user: { id: 'fixture-user', name: 'fixture-user', display_name: 'Fixture User' }
};

export const RUSTDESK_PRO_WRONG_EMAIL_RESPONSE: RustDeskProLoginFixture = {
  error: 'invalid email verification code'
};

export const RUSTDESK_PRO_WRONG_TOTP_RESPONSE: RustDeskProLoginFixture = {
  error: 'wrong tfa code'
};

export const RUSTDESK_PRO_EXPIRED_RESPONSE: RustDeskProLoginFixture = {
  error: 'challenge expired'
};

export const RUSTDESK_PRO_UNSUPPORTED_RESPONSE: RustDeskProLoginFixture = {
  error: 'unsupported challenge type'
};

export const RUSTDESK_PRO_EXTENDED_FIELD_REJECTION_RESPONSE: RustDeskProLoginFixture = {
  unsupportedFields: ['deviceInfo']
};

/**
 * Address-book contract fixtures are synthetic and redacted.  They mirror the
 * pinned upstream client shape without retaining production GUIDs, peers,
 * aliases, notes, access tokens, or credentials.
 */
export const RUSTDESK_PRO_AB_MODERN_PERSONAL_RESPONSE: RustDeskProAddressBookProfileFixture = {
  guid: 'fixture-personal-book-guid',
  name: 'My address book',
  owner: 'fixture-owner',
  share_rule: 'fullControl'
};

export const RUSTDESK_PRO_AB_MODERN_SHARED_PROFILES_PAGE_ONE: RustDeskProAddressBookProfilePageFixture = {
  total: 3,
  current: 1,
  pageSize: 100,
  data: [
    {
      guid: 'fixture-shared-read-guid', name: 'Shared Read', owner: 'fixture-owner-a',
      share_rule: 'read'
    },
    {
      guid: 'fixture-shared-write-guid', name: 'Shared Write', owner: 'fixture-owner-b',
      share_rule: 'readWrite'
    },
    {
      guid: 'fixture-shared-full-guid', name: 'Shared Full', owner: 'fixture-owner-c',
      share_rule: 'fullControl'
    }
  ]
};

export const RUSTDESK_PRO_AB_TAGS_PERSONAL_RESPONSE: RustDeskProAddressBookTagFixture[] = [
  { name: 'Ops', color: 4281545523 },
  { name: '研发/夜班', color: 4286611711 }
];

export const RUSTDESK_PRO_AB_TAGS_SHARED_RESPONSE: RustDeskProAddressBookTagFixture[] = [
  { name: 'Ops', color: 4294901760 }
];

export const RUSTDESK_PRO_AB_PERSONAL_PEERS_PAGE_ONE: RustDeskProAddressBookPeerPageFixture = {
  total: 2,
  current: 1,
  pageSize: 100,
  data: [
    {
      id: 'fixture-peer-one', alias: 'Ops alias', hostname: 'host-one',
      platform: 'Windows', note: 'fixture note',
      tags: [{ name: 'Ops', color: 4281545523 }]
    },
    {
      id: 'fixture-peer-duplicate', alias: 'Personal alias', hostname: 'shared-host',
      platform: 'Linux', tags: []
    }
  ]
};

export const RUSTDESK_PRO_AB_SHARED_PEERS_PAGE_ONE: RustDeskProAddressBookPeerPageFixture = {
  total: 1,
  current: 1,
  pageSize: 100,
  data: [
    {
      id: 'fixture-peer-duplicate', membership_id: 'fixture-membership-shared',
      alias: 'Shared alias', hostname: 'shared-host', platform: 'Linux',
      note: 'shared note', tags: [{ name: 'Ops', color: 4294901760 }]
    }
  ]
};

const RUSTDESK_PRO_AB_LEGACY_DATA: RustDeskProLegacyDataFixture = {
    tags: ['Legacy'],
    peers: [{ id: 'fixture-legacy-peer', alias: 'Legacy alias', hostname: 'legacy-host',
      platform: 'macOS', tags: ['Legacy'], note: 'legacy note' }]
};

export const RUSTDESK_PRO_AB_LEGACY_RESPONSE: RustDeskProLegacyResponseFixture = {
  data: JSON.stringify(RUSTDESK_PRO_AB_LEGACY_DATA)
};

export const RUSTDESK_PRO_AB_PAGINATION_FAILURE_RESPONSE: RustDeskProAddressBookErrorFixture = {
  error: 'fixture page unavailable', code: 'page_failed', detail: 'fixture detail'
};

export const RUSTDESK_PRO_AB_TAG_FAILURE_RESPONSE: RustDeskProAddressBookErrorFixture = {
  error: 'fixture tag endpoint unavailable', code: 'tag_endpoint_failed'
};
