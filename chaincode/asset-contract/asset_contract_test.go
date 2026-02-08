package main

import (
    "encoding/json"
    "testing"

    "github.com/hyperledger/fabric-chaincode-go/shimtest"
    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

func newStub(t *testing.T) *shimtest.MockStub {
    t.Helper()
    cc, err := contractapi.NewChaincode(new(AssetContract))
    if err != nil {
        t.Fatalf("new chaincode: %v", err)
    }
    stub := shimtest.NewMockStub("assetcc", cc)
    res := stub.MockInit("tx0", [][]byte{[]byte("Init")})
    if res.Status != 200 {
        t.Fatalf("init failed: %d %s", res.Status, string(res.Message))
    }
    return stub
}

func invoke(stub *shimtest.MockStub, fcn string, args ...string) *shimtest.MockInvokeResponse {
    var bargs [][]byte
    bargs = append(bargs, []byte(fcn))
    for _, a := range args {
        bargs = append(bargs, []byte(a))
    }
    return stub.MockInvoke("tx", bargs)
}

func mustOK(t *testing.T, res *shimtest.MockInvokeResponse) []byte {
    t.Helper()
    if res.Status != 200 {
        t.Fatalf("invoke failed: %d %s", res.Status, string(res.Message))
    }
    return res.Payload
}

func TestAssetLifecycle(t *testing.T) {
    stub := newStub(t)

    // CreateAsset(assetID, categoryID, ownerUnitID, locationID)
    payload := mustOK(t, invoke(stub, "CreateAsset", "A-001", "CAT-01", "UNIT-01", "LOC-01"))
    var st AssetState
    if err := json.Unmarshal(payload, &st); err != nil {
        t.Fatalf("unmarshal: %v", err)
    }
    if st.AssetID != "A-001" || st.Status != StatusActive {
        t.Fatalf("unexpected state after create: %+v", st)
    }

    // GetAsset
    payload = mustOK(t, invoke(stub, "GetAsset", "A-001"))
    if err := json.Unmarshal(payload, &st); err != nil {
        t.Fatalf("unmarshal get: %v", err)
    }

    // TransferAsset(assetID, toOwnerUnitID, toLocationID, transferType, note, docCID)
    mustOK(t, invoke(stub, "TransferAsset", "A-001", "UNIT-02", "LOC-02", "borrow", "for usage", ""))
    payload = mustOK(t, invoke(stub, "GetAsset", "A-001"))
    if err := json.Unmarshal(payload, &st); err != nil {
        t.Fatalf("unmarshal after transfer: %v", err)
    }
    if st.OwnerUnitID != "UNIT-02" || st.LocationID != "LOC-02" || st.Status != StatusBorrowed {
        t.Fatalf("unexpected state after transfer: %+v", st)
    }

    // UpdateMaintenance(assetID, date, mtype, note, cost, technicianID, docCID)
    mustOK(t, invoke(stub, "UpdateMaintenance", "A-001", "", "repair", "fix screen", "150", "TECH-01", ""))
    payload = mustOK(t, invoke(stub, "GetAsset", "A-001"))
    if err := json.Unmarshal(payload, &st); err != nil {
        t.Fatalf("unmarshal after maintenance: %v", err)
    }
    if st.Status != StatusMaintenance {
        t.Fatalf("expected status maintenance, got %s", st.Status)
    }

    // DisposeAsset(assetID, date, reason, docCID)
    mustOK(t, invoke(stub, "DisposeAsset", "A-001", "", "broken beyond repair", ""))
    payload = mustOK(t, invoke(stub, "GetAsset", "A-001"))
    if err := json.Unmarshal(payload, &st); err != nil {
        t.Fatalf("unmarshal after dispose: %v", err)
    }
    if st.Status != StatusDisposed {
        t.Fatalf("expected status disposed, got %s", st.Status)
    }

    // GetAllAssets
    payload = mustOK(t, invoke(stub, "GetAllAssets"))
    var list []AssetState
    if err := json.Unmarshal(payload, &list); err != nil {
        t.Fatalf("unmarshal list: %v", err)
    }
    if len(list) == 0 {
        t.Fatalf("expected at least 1 asset")
    }
}

