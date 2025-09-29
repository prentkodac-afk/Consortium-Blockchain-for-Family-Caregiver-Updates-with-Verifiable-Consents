// ConsentRegistry.test.ts
import { describe, expect, it, beforeEach } from "vitest";

// Interfaces for type safety
interface ClarityResponse<T> {
  ok: boolean;
  value: T | number; // number for error codes
}

interface ConsentRecord {
  expiry: number;
  active: boolean;
  details: string;
  grantedAt: number;
}

interface HistoryRecord {
  patient: string;
  grantee: string;
  action: string;
  status: string;
  timestamp: number;
  details: string;
}

interface DelegateRecord {
  permissions: string[];
  expiry: number;
  active: boolean;
}

interface UserRole {
  role: string;
  verified: boolean;
}

interface ContractState {
  consents: Map<string, ConsentRecord>; // Key: `${patient}-${grantee}-${action}`
  consentHistory: Map<number, HistoryRecord>;
  delegates: Map<string, DelegateRecord>; // Key: `${patient}-${delegate}`
  userRoles: Map<string, UserRole>;
  contractPaused: boolean;
  admin: string;
  consentCounter: number;
}

// Mock contract implementation
class ConsentRegistryMock {
  private state: ContractState = {
    consents: new Map(),
    consentHistory: new Map(),
    delegates: new Map(),
    userRoles: new Map(),
    contractPaused: false,
    admin: "deployer",
    consentCounter: 0,
  };

  private ERR_NOT_PATIENT = 1;
  private ERR_NOT_AUTHORIZED = 2;
  private ERR_CONSENT_EXISTS = 3;
  private ERR_NO_CONSENT = 4;
  private ERR_EXPIRED = 5;
  private ERR_INVALID_ACTION = 6;
  private ERR_INVALID_EXPIRY = 7;
  private ERR_NOT_DELEGATE = 8;
  private ERR_BATCH_LIMIT_EXCEEDED = 9;
  private ERR_INVALID_ROLE = 10;
  private ERR_CONTRACT_PAUSED = 11;
  private MAX_BATCH_SIZE = 10;
  private MAX_ACTION_LEN = 20;
  private MAX_DETAILS_LEN = 512;
  private blockHeight = 100; // Mock block height

  // Mock block height setter for testing expiry
  setBlockHeight(height: number) {
    this.blockHeight = height;
  }

  pauseContract(caller: string): ClarityResponse<boolean> {
    if (caller !== this.state.admin) {
      return { ok: false, value: this.ERR_NOT_AUTHORIZED };
    }
    this.state.contractPaused = true;
    return { ok: true, value: true };
  }

  unpauseContract(caller: string): ClarityResponse<boolean> {
    if (caller !== this.state.admin) {
      return { ok: false, value: this.ERR_NOT_AUTHORIZED };
    }
    this.state.contractPaused = false;
    return { ok: true, value: true };
  }

  registerUser(caller: string, role: string): ClarityResponse<boolean> {
    if (!["Patient", "FamilyMember", "Caregiver"].includes(role)) {
      return { ok: false, value: this.ERR_INVALID_ROLE };
    }
    this.state.userRoles.set(caller, { role, verified: true });
    return { ok: true, value: true };
  }

  grantConsent(caller: string, grantee: string, action: string, expiry: number, details: string): ClarityResponse<number> {
    if (this.state.contractPaused) {
      return { ok: false, value: this.ERR_CONTRACT_PAUSED };
    }
    if (this.state.userRoles.get(caller)?.role !== "Patient") {
      return { ok: false, value: this.ERR_NOT_PATIENT };
    }
    if (expiry <= this.blockHeight) {
      return { ok: false, value: this.ERR_INVALID_EXPIRY };
    }
    if (action.length > this.MAX_ACTION_LEN) {
      return { ok: false, value: this.ERR_INVALID_ACTION };
    }
    if (details.length > this.MAX_DETAILS_LEN) {
      return { ok: false, value: this.ERR_INVALID_ACTION };
    }
    const key = `${caller}-${grantee}-${action}`;
    if (this.state.consents.has(key)) {
      return { ok: false, value: this.ERR_CONSENT_EXISTS };
    }
    this.state.consents.set(key, { expiry, active: true, details, grantedAt: this.blockHeight });
    const id = this.state.consentCounter;
    this.state.consentHistory.set(id, {
      patient: caller,
      grantee,
      action,
      status: "Granted",
      timestamp: this.blockHeight,
      details,
    });
    this.state.consentCounter += 1;
    return { ok: true, value: id };
  }

  revokeConsent(caller: string, grantee: string, action: string): ClarityResponse<number> {
    if (this.state.contractPaused) {
      return { ok: false, value: this.ERR_CONTRACT_PAUSED };
    }
    if (this.state.userRoles.get(caller)?.role !== "Patient") {
      return { ok: false, value: this.ERR_NOT_PATIENT };
    }
    const key = `${caller}-${grantee}-${action}`;
    const consent = this.state.consents.get(key);
    if (!consent) {
      return { ok: false, value: this.ERR_NO_CONSENT };
    }
    this.state.consents.set(key, { ...consent, active: false, expiry: 0 });
    const id = this.state.consentCounter;
    this.state.consentHistory.set(id, {
      patient: caller,
      grantee,
      action,
      status: "Revoked",
      timestamp: this.blockHeight,
      details: consent.details,
    });
    this.state.consentCounter += 1;
    return { ok: true, value: id };
  }

  delegateConsent(caller: string, delegate: string, permissions: string[], expiry: number): ClarityResponse<boolean> {
    if (this.state.contractPaused) {
      return { ok: false, value: this.ERR_CONTRACT_PAUSED };
    }
    if (this.state.userRoles.get(caller)?.role !== "Patient") {
      return { ok: false, value: this.ERR_NOT_PATIENT };
    }
    if (expiry <= this.blockHeight) {
      return { ok: false, value: this.ERR_INVALID_EXPIRY };
    }
    const key = `${caller}-${delegate}`;
    this.state.delegates.set(key, { permissions, expiry, active: true });
    return { ok: true, value: true };
  }

  grantConsentAsDelegate(caller: string, patient: string, grantee: string, action: string, expiry: number, details: string): ClarityResponse<number> {
    if (this.state.contractPaused) {
      return { ok: false, value: this.ERR_CONTRACT_PAUSED };
    }
    const delegateKey = `${patient}-${caller}`;
    const delegation = this.state.delegates.get(delegateKey);
    if (!delegation || !delegation.active || delegation.expiry <= this.blockHeight || !delegation.permissions.includes(action)) {
      return { ok: false, value: this.ERR_NOT_DELEGATE };
    }
    if (expiry <= this.blockHeight) {
      return { ok: false, value: this.ERR_INVALID_EXPIRY };
    }
    if (action.length > this.MAX_ACTION_LEN) {
      return { ok: false, value: this.ERR_INVALID_ACTION };
    }
    if (details.length > this.MAX_DETAILS_LEN) {
      return { ok: false, value: this.ERR_INVALID_ACTION };
    }
    const key = `${patient}-${grantee}-${action}`;
    if (this.state.consents.has(key)) {
      return { ok: false, value: this.ERR_CONSENT_EXISTS };
    }
    this.state.consents.set(key, { expiry, active: true, details, grantedAt: this.blockHeight });
    const id = this.state.consentCounter;
    this.state.consentHistory.set(id, {
      patient,
      grantee,
      action,
      status: "Granted (Delegate)",
      timestamp: this.blockHeight,
      details,
    });
    this.state.consentCounter += 1;
    return { ok: true, value: id };
  }

  batchGrantConsents(caller: string, grantees: string[], action: string, expiry: number, details: string): ClarityResponse<number> {
    if (this.state.contractPaused) {
      return { ok: false, value: this.ERR_CONTRACT_PAUSED };
    }
    if (this.state.userRoles.get(caller)?.role !== "Patient") {
      return { ok: false, value: this.ERR_NOT_PATIENT };
    }
    if (grantees.length > this.MAX_BATCH_SIZE) {
      return { ok: false, value: this.ERR_BATCH_LIMIT_EXCEEDED };
    }
    let count = 0;
    for (const grantee of grantees) {
      const result = this.grantConsent(caller, grantee, action, expiry, details);
      if (!result.ok) {
        return result;
      }
      count += 1;
    }
    return { ok: true, value: count };
  }

  verifyConsent(patient: string, grantee: string, action: string): ClarityResponse<boolean> {
    const key = `${patient}-${grantee}-${action}`;
    const consent = this.state.consents.get(key);
    if (!consent) {
      return { ok: true, value: false };
    }
    return { ok: true, value: consent.active && consent.expiry > this.blockHeight };
  }

  getConsentDetails(patient: string, grantee: string, action: string): ClarityResponse<ConsentRecord | null> {
    const key = `${patient}-${grantee}-${action}`;
    return { ok: true, value: this.state.consents.get(key) ?? null };
  }

  getConsentHistory(consentId: number): ClarityResponse<HistoryRecord | null> {
    return { ok: true, value: this.state.consentHistory.get(consentId) ?? null };
  }

  getDelegateDetails(patient: string, delegate: string): ClarityResponse<DelegateRecord | null> {
    const key = `${patient}-${delegate}`;
    return { ok: true, value: this.state.delegates.get(key) ?? null };
  }

  getUserRole(user: string): ClarityResponse<string | null> {
    return { ok: true, value: this.state.userRoles.get(user)?.role ?? null };
  }

  isContractPaused(): ClarityResponse<boolean> {
    return { ok: true, value: this.state.contractPaused };
  }
}

// Test setup
const accounts = {
  deployer: "deployer",
  patient: "patient1",
  family: "family1",
  caregiver: "caregiver1",
  delegate: "delegate1",
};

describe("ConsentRegistry Contract", () => {
  let contract: ConsentRegistryMock;

  beforeEach(() => {
    contract = new ConsentRegistryMock();
    contract.setBlockHeight(100);
    // Register users
    contract.registerUser(accounts.patient, "Patient");
    contract.registerUser(accounts.family, "FamilyMember");
    contract.registerUser(accounts.caregiver, "Caregiver");
    contract.registerUser(accounts.delegate, "FamilyMember");
  });

  it("should initialize correctly", () => {
    expect(contract.isContractPaused()).toEqual({ ok: true, value: false });
    expect(contract.getUserRole(accounts.patient)).toEqual({ ok: true, value: "Patient" });
  });

  it("should allow patient to grant consent", () => {
    const result = contract.grantConsent(accounts.patient, accounts.family, "view-update", 200, "Family access");
    expect(result).toEqual({ ok: true, value: 0 });
    const details = contract.getConsentDetails(accounts.patient, accounts.family, "view-update");
    expect(details).toEqual({
      ok: true,
      value: { expiry: 200, active: true, details: "Family access", grantedAt: 100 },
    });
    const history = contract.getConsentHistory(0);
    expect(history).toEqual({
      ok: true,
      value: expect.objectContaining({
        status: "Granted",
        details: "Family access",
      }),
    });
  });

  it("should prevent non-patient from granting consent", () => {
    const result = contract.grantConsent(accounts.family, accounts.caregiver, "view-update", 200, "Invalid");
    expect(result).toEqual({ ok: false, value: 1 });
  });

  it("should allow patient to revoke consent", () => {
    contract.grantConsent(accounts.patient, accounts.family, "view-update", 200, "Family access");
    const revokeResult = contract.revokeConsent(accounts.patient, accounts.family, "view-update");
    expect(revokeResult).toEqual({ ok: true, value: 1 });
    const verify = contract.verifyConsent(accounts.patient, accounts.family, "view-update");
    expect(verify).toEqual({ ok: true, value: false });
  });

  it("should handle expiry in verification", () => {
    contract.grantConsent(accounts.patient, accounts.family, "view-update", 150, "Family access");
    let verify = contract.verifyConsent(accounts.patient, accounts.family, "view-update");
    expect(verify).toEqual({ ok: true, value: true });
    contract.setBlockHeight(160);
    verify = contract.verifyConsent(accounts.patient, accounts.family, "view-update");
    expect(verify).toEqual({ ok: true, value: false });
  });

  it("should allow delegation and delegate granting", () => {
    const delegateResult = contract.delegateConsent(accounts.patient, accounts.delegate, ["view-update"], 200);
    expect(delegateResult).toEqual({ ok: true, value: true });
    const grantAsDelegate = contract.grantConsentAsDelegate(accounts.delegate, accounts.patient, accounts.family, "view-update", 200, "Delegated access");
    expect(grantAsDelegate).toEqual({ ok: true, value: 0 });
    const history = contract.getConsentHistory(0);
    expect(history).toEqual({
      ok: true,
      value: expect.objectContaining({
        status: "Granted (Delegate)",
      }),
    });
  });

  it("should prevent unauthorized delegation granting", () => {
    const grantAsDelegate = contract.grantConsentAsDelegate(accounts.family, accounts.patient, accounts.caregiver, "view-update", 200, "Invalid");
    expect(grantAsDelegate).toEqual({ ok: false, value: 8 });
  });

  it("should handle batch grants", () => {
    const grantees = [accounts.family, accounts.caregiver];
    const batchResult = contract.batchGrantConsents(accounts.patient, grantees, "view-update", 200, "Batch access");
    expect(batchResult).toEqual({ ok: true, value: 2 });
    const verify1 = contract.verifyConsent(accounts.patient, accounts.family, "view-update");
    expect(verify1).toEqual({ ok: true, value: true });
    const verify2 = contract.verifyConsent(accounts.patient, accounts.caregiver, "view-update");
    expect(verify2).toEqual({ ok: true, value: true });
  });

  it("should prevent batch exceeding limit", () => {
    const grantees = Array(11).fill(accounts.family);
    const batchResult = contract.batchGrantConsents(accounts.patient, grantees, "view-update", 200, "Too many");
    expect(batchResult).toEqual({ ok: false, value: 9 });
  });

  it("should pause and prevent operations", () => {
    contract.pauseContract(accounts.deployer);
    const grantResult = contract.grantConsent(accounts.patient, accounts.family, "view-update", 200, "Paused");
    expect(grantResult).toEqual({ ok: false, value: 11 });
  });
});