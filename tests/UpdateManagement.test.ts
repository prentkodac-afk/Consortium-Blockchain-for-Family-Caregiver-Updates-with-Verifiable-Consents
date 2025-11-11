// UpdateManagement.test.ts
import { describe, expect, it, vi, beforeEach } from "vitest";

// Interfaces for type safety
interface ClarityResponse<T> {
  ok: boolean;
  value: T | number; // number for error codes
}

interface UpdateRecord {
  patient: string;
  sender: string;
  contentHash: string; // Represent buff 32 as string for mock
  metadata: string;
  category: string;
  attachments: string[]; // List of hashes as strings
  timestamp: number;
  editedAt?: number | null;
  isActive: boolean;
}

interface ContractState {
  updates: Map<number, UpdateRecord>;
  patientUpdates: Map<string, number[]>;
  updateCounter: number;
  maxUpdatesPerPatient: number;
}

// Mock contract implementation
class UpdateManagementMock {
  private state: ContractState = {
    updates: new Map(),
    patientUpdates: new Map(),
    updateCounter: 0,
    maxUpdatesPerPatient: 100,
  };

  private ERR_UNAUTHORIZED = 100;
  private ERR_INVALID_PATIENT = 101;
  private ERR_UPDATE_NOT_FOUND = 102;
  private ERR_INVALID_METADATA = 103;
  private ERR_INVALID_CATEGORY = 104;
  private ERR_INVALID_ATTACHMENT = 105;
  private ERR_UPDATE_EXPIRED = 106;
  private ERR_TOO_MANY_UPDATES = 107;

  // Mock external calls
  private mockVerifyConsent(patient: string, sender: string, action: string): boolean {
    // Simplified mock: always true for testing, but can be configured
    return true;
  }

  private mockGetUserRole(user: string): string | null {
    // Mock: deployer is Admin
    return user === "deployer" ? "Admin" : null;
  }

  postUpdate(
    caller: string,
    patient: string,
    contentHash: string,
    metadata: string,
    category: string,
    attachments: string[]
  ): ClarityResponse<number> {
    if (!this.mockVerifyConsent(patient, caller, "post-update") && caller !== patient) {
      return { ok: false, value: this.ERR_UNAUTHORIZED };
    }
    if (metadata.length > 512) {
      return { ok: false, value: this.ERR_INVALID_METADATA };
    }
    if (category.length > 50) {
      return { ok: false, value: this.ERR_INVALID_CATEGORY };
    }
    if (attachments.length > 5) {
      return { ok: false, value: this.ERR_INVALID_ATTACHMENT };
    }

    const id = this.state.updateCounter;
    const currentPatientUpdates = this.state.patientUpdates.get(patient) ?? [];
    let newList = currentPatientUpdates;
    if (currentPatientUpdates.length >= this.state.maxUpdatesPerPatient) {
      newList = currentPatientUpdates.slice(1);
    }
    newList.push(id);

    this.state.updates.set(id, {
      patient,
      sender: caller,
      contentHash,
      metadata,
      category,
      attachments,
      timestamp: Date.now(), // Simulate block-height
      editedAt: null,
      isActive: true,
    });
    this.state.patientUpdates.set(patient, newList);
    this.state.updateCounter++;

    return { ok: true, value: id };
  }

  editUpdate(
    caller: string,
    id: number,
    newContentHash: string,
    newMetadata: string,
    newCategory: string,
    newAttachments: string[]
  ): ClarityResponse<boolean> {
    const existing = this.state.updates.get(id);
    if (!existing) {
      return { ok: false, value: this.ERR_UPDATE_NOT_FOUND };
    }
    const patient = existing.patient;
    if (
      caller !== existing.sender &&
      caller !== patient &&
      !this.mockVerifyConsent(patient, caller, "edit-update")
    ) {
      return { ok: false, value: this.ERR_UNAUTHORIZED };
    }
    if (newMetadata.length > 512) {
      return { ok: false, value: this.ERR_INVALID_METADATA };
    }
    if (newCategory.length > 50) {
      return { ok: false, value: this.ERR_INVALID_CATEGORY };
    }
    if (newAttachments.length > 5) {
      return { ok: false, value: this.ERR_INVALID_ATTACHMENT };
    }

    this.state.updates.set(id, {
      ...existing,
      contentHash: newContentHash,
      metadata: newMetadata,
      category: newCategory,
      attachments: newAttachments,
      editedAt: Date.now(),
      isActive: true,
    });

    return { ok: true, value: true };
  }

  deleteUpdate(caller: string, id: number): ClarityResponse<boolean> {
    const existing = this.state.updates.get(id);
    if (!existing) {
      return { ok: false, value: this.ERR_UPDATE_NOT_FOUND };
    }
    const patient = existing.patient;
    if (caller !== patient && !this.mockVerifyConsent(patient, caller, "delete-update")) {
      return { ok: false, value: this.ERR_UNAUTHORIZED };
    }

    this.state.updates.set(id, { ...existing, isActive: false });

    return { ok: true, value: true };
  }

  setUpdateExpiry(caller: string, id: number, expiryBlock: number): ClarityResponse<boolean> {
    const existing = this.state.updates.get(id);
    if (!existing) {
      return { ok: false, value: this.ERR_UPDATE_NOT_FOUND };
    }
    if (caller !== existing.patient) {
      return { ok: false, value: this.ERR_UNAUTHORIZED };
    }
    if (expiryBlock <= Date.now()) { // Simulate block-height
      return { ok: false, value: this.ERR_UPDATE_EXPIRED };
    }

    // Add expiry if not present, or update
    this.state.updates.set(id, { ...existing, expiry: expiryBlock });

    return { ok: true, value: true };
  }

  getUpdate(id: number): ClarityResponse<UpdateRecord | null> {
    const update = this.state.updates.get(id);
    return { ok: true, value: update ?? null };
  }

  getUpdatesForPatient(patient: string): ClarityResponse<number[]> {
    return { ok: true, value: this.state.patientUpdates.get(patient) ?? [] };
  }

  getUpdatesByCategory(patient: string, category: string): ClarityResponse<number[]> {
    const allIds = this.state.patientUpdates.get(patient) ?? [];
    const filtered = allIds.filter((id) => {
      const update = this.state.updates.get(id);
      return update && update.category === category && update.isActive;
    });
    return { ok: true, value: filtered };
  }

  getUpdateCount(patient: string): ClarityResponse<number> {
    return { ok: true, value: (this.state.patientUpdates.get(patient) ?? []).length };
  }

  isUpdateActive(id: number): ClarityResponse<boolean> {
    const update = this.state.updates.get(id);
    return { ok: true, value: !!update?.isActive };
  }

  setMaxUpdatesPerPatient(caller: string, newMax: number): ClarityResponse<boolean> {
    if (this.mockGetUserRole(caller) !== "Admin") {
      return { ok: false, value: this.ERR_UNAUTHORIZED };
    }
    this.state.maxUpdatesPerPatient = newMax;
    return { ok: true, value: true };
  }

  batchPostUpdates(
    caller: string,
    patient: string,
    updatesList: Array<{
      contentHash: string;
      metadata: string;
      category: string;
      attachments: string[];
    }>
  ): ClarityResponse<{ success: number; failed: number }> {
    let success = 0;
    let failed = 0;
    updatesList.forEach((updateItem) => {
      const result = this.postUpdate(
        caller,
        patient,
        updateItem.contentHash,
        updateItem.metadata,
        updateItem.category,
        updateItem.attachments
      );
      if (result.ok) success++;
      else failed++;
    });
    return { ok: true, value: { success, failed } };
  }
}

// Test setup
const accounts = {
  deployer: "deployer",
  patient: "wallet_1",
  sender: "wallet_2",
  other: "wallet_3",
};

describe("UpdateManagement Contract", () => {
  let contract: UpdateManagementMock;

  beforeEach(() => {
    contract = new UpdateManagementMock();
    vi.resetAllMocks();
  });

  it("should post a new update successfully", () => {
    const result = contract.postUpdate(
      accounts.sender,
      accounts.patient,
      "hash123",
      "Medication administered",
      "health",
      ["attach1"]
    );
    expect(result).toEqual({ ok: true, value: 0 });
    expect(contract.getUpdateCount(accounts.patient)).toEqual({ ok: true, value: 1 });
    const update = contract.getUpdate(0);
    expect(update).toEqual({
      ok: true,
      value: expect.objectContaining({
        patient: accounts.patient,
        sender: accounts.sender,
        metadata: "Medication administered",
        category: "health",
        isActive: true,
      }),
    });
  });

  it("should prevent posting without permission", () => {
    // Mock verifyConsent to false
    (contract as any).mockVerifyConsent = () => false;
    const result = contract.postUpdate(
      accounts.other,
      accounts.patient,
      "hash123",
      "Unauthorized update",
      "health",
      []
    );
    expect(result).toEqual({ ok: false, value: 100 });
  });

  it("should reject invalid metadata length", () => {
    const longMetadata = "a".repeat(513);
    const result = contract.postUpdate(
      accounts.patient,
      accounts.patient,
      "hash123",
      longMetadata,
      "health",
      []
    );
    expect(result).toEqual({ ok: false, value: 103 });
  });

  it("should edit an existing update", () => {
    contract.postUpdate(accounts.sender, accounts.patient, "oldhash", "Old note", "oldcat", []);
    const editResult = contract.editUpdate(
      accounts.sender,
      0,
      "newhash",
      "Updated note",
      "newcat",
      ["newattach"]
    );
    expect(editResult).toEqual({ ok: true, value: true });
    const updated = contract.getUpdate(0);
    expect(updated).toEqual({
      ok: true,
      value: expect.objectContaining({
        contentHash: "newhash",
        metadata: "Updated note",
        category: "newcat",
        editedAt: expect.any(Number),
      }),
    });
  });

  it("should prevent editing without permission", () => {
    contract.postUpdate(accounts.sender, accounts.patient, "hash", "Note", "cat", []);
    // Mock verifyConsent to false
    (contract as any).mockVerifyConsent = () => false;
    const result = contract.editUpdate(
      accounts.other,
      0,
      "newhash",
      "New note",
      "newcat",
      []
    );
    expect(result).toEqual({ ok: false, value: 100 });
  });

  it("should delete an update", () => {
    contract.postUpdate(accounts.patient, accounts.patient, "hash", "Note", "cat", []);
    const deleteResult = contract.deleteUpdate(accounts.patient, 0);
    expect(deleteResult).toEqual({ ok: true, value: true });
    expect(contract.isUpdateActive(0)).toEqual({ ok: true, value: false });
  });

  it("should set max updates per patient as admin", () => {
    const result = contract.setMaxUpdatesPerPatient(accounts.deployer, 50);
    expect(result).toEqual({ ok: true, value: true });
    // Verify by posting many and checking rotation
    for (let i = 0; i < 101; i++) {
      contract.postUpdate(accounts.patient, accounts.patient, `hash${i}`, "Note", "cat", []);
    }
    expect(contract.getUpdateCount(accounts.patient)).toEqual({ ok: true, value: 50 });
  });

  it("should handle batch posting", () => {
    const batch = [
      { contentHash: "h1", metadata: "m1", category: "c1", attachments: [] },
      { contentHash: "h2", metadata: "m2", category: "c2", attachments: [] },
    ];
    const result = contract.batchPostUpdates(accounts.patient, accounts.patient, batch);
    expect(result).toEqual({ ok: true, value: { success: 2, failed: 0 } });
    expect(contract.getUpdateCount(accounts.patient)).toEqual({ ok: true, value: 2 });
  });

  it("should filter updates by category", () => {
    contract.postUpdate(accounts.patient, accounts.patient, "h1", "Health note", "health", []);
    contract.postUpdate(accounts.patient, accounts.patient, "h2", "Diet note", "diet", []);
    const filtered = contract.getUpdatesByCategory(accounts.patient, "health");
    expect(filtered).toEqual({ ok: true, value: [0] }); // Assuming order
  });
});