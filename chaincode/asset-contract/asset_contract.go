package main

import (
    "encoding/json"
    "errors"
    "fmt"
    "strings"
    "time"

    "github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// AssetContract implements lifecycle operations for assets.
type AssetContract struct {
    contractapi.Contract
}

// Status values
const (
    StatusActive      = "active"
    StatusBorrowed    = "borrowed"
    StatusMaintenance = "maintenance"
    StatusDisposed    = "disposed"
)

// Key prefixes
const (
    keyAssetPrefix  = "ASSET:"
    keyXferPrefix   = "XFER:"
    keyMaintPrefix  = "MAINT:"
    keyDisposePrefix= "DISP:"
)

// AssetState is the minimal on-chain state for an asset
type AssetState struct {
    AssetID     string `json:"assetId"`
    OwnerUnitID string `json:"ownerUnitId"`
    LocationID  string `json:"locationId"`
    Status      string `json:"status"` // active|borrowed|maintenance|disposed
    CategoryID  string `json:"categoryId"`
    CreatedAt   string `json:"createdAt"` // RFC3339
    UpdatedAt   string `json:"updatedAt"` // RFC3339
}

// TransferLog is an immutable event record
type TransferLog struct {
    AssetID         string `json:"assetId"`
    FromOwnerUnitID string `json:"fromOwnerUnitId"`
    ToOwnerUnitID   string `json:"toOwnerUnitId"`
    FromLocationID  string `json:"fromLocationId"`
    ToLocationID    string `json:"toLocationId"`
    TransferType    string `json:"transferType"` // borrow|permanent
    Date            string `json:"date"`        // RFC3339
    Note            string `json:"note"`
    DocCID          string `json:"docCid,omitempty"`
    TxID            string `json:"txId,omitempty"`
}

// MaintenanceLog is an immutable event record
type MaintenanceLog struct {
    AssetID      string  `json:"assetId"`
    Date         string  `json:"date"` // RFC3339
    Type         string  `json:"type"`
    Note         string  `json:"note"`
    Cost         float64 `json:"cost"`
    TechnicianID string  `json:"technicianId"`
    DocCID       string  `json:"docCid,omitempty"`
    TxID         string  `json:"txId,omitempty"`
}

// DisposeLog is an immutable event record
type DisposeLog struct {
    AssetID string `json:"assetId"`
    Date    string `json:"date"` // RFC3339
    Reason  string `json:"reason"`
    DocCID  string `json:"docCid,omitempty"`
    TxID    string `json:"txId,omitempty"`
}

// TimelineEvent is a unified history entry for GetAssetHistory
type TimelineEvent struct {
    Kind     string          `json:"kind"`      // ASSET_STATE | TRANSFER | MAINTENANCE | DISPOSE
    Key      string          `json:"key"`
    Date     string          `json:"date"`      // RFC3339 (state uses UpdatedAt)
    TxID     string          `json:"txId,omitempty"`
    Payload  map[string]interface{} `json:"payload"`   // underlying struct as map
}

func nowRFC3339(ctx contractapi.TransactionContextInterface) string {
    ts, err := ctx.GetStub().GetTxTimestamp()
    if err != nil {
        return time.Now().UTC().Format(time.RFC3339)
    }
    t := time.Unix(ts.Seconds, int64(ts.Nanos)).UTC()
    return t.Format(time.RFC3339)
}

func assetKey(id string) string { return keyAssetPrefix + id }
func xferPrefixFor(id string) string { return keyXferPrefix + id + ":" }
func maintPrefixFor(id string) string { return keyMaintPrefix + id + ":" }
func dispPrefixFor(id string) string { return keyDisposePrefix + id + ":" }

func prefixRange(prefix string) (string, string) {
    // End sentinel using '~' which is higher than base64/hex/letters in ASCII
    return prefix, prefix + "~"
}

// InitLedger seeds optional demo data (no-op by default)
func (c *AssetContract) InitLedger(ctx contractapi.TransactionContextInterface) error {
    return nil
}

// CreateAsset registers/activates an asset on-chain
func (c *AssetContract) CreateAsset(ctx contractapi.TransactionContextInterface,
    assetID, categoryID, ownerUnitID, locationID string) (*AssetState, error) {

    if strings.TrimSpace(assetID) == "" {
        return nil, errors.New("assetId is required")
    }
    k := assetKey(assetID)
    exists, err := c.assetExists(ctx, k)
    if err != nil {
        return nil, err
    }
    if exists {
        return nil, fmt.Errorf("asset %s already exists", assetID)
    }

    now := nowRFC3339(ctx)
    st := &AssetState{
        AssetID:     assetID,
        OwnerUnitID: ownerUnitID,
        LocationID:  locationID,
        Status:      StatusActive,
        CategoryID:  categoryID,
        CreatedAt:   now,
        UpdatedAt:   now,
    }
    b, _ := json.Marshal(st)
    if err := ctx.GetStub().PutState(k, b); err != nil {
        return nil, err
    }
    // emit event
    _ = ctx.GetStub().SetEvent("CreateAsset", b)
    return st, nil
}

// TransferAsset updates owner/location and writes a transfer log
func (c *AssetContract) TransferAsset(ctx contractapi.TransactionContextInterface,
    assetID, toOwnerUnitID, toLocationID, transferType, note, docCID string) (*TransferLog, error) {

    k := assetKey(assetID)
    st, err := c.getAsset(ctx, k)
    if err != nil { return nil, err }

    now := nowRFC3339(ctx)
    log := &TransferLog{
        AssetID:         assetID,
        FromOwnerUnitID: st.OwnerUnitID,
        ToOwnerUnitID:   toOwnerUnitID,
        FromLocationID:  st.LocationID,
        ToLocationID:    toLocationID,
        TransferType:    transferType,
        Date:            now,
        Note:            note,
        DocCID:          strings.TrimSpace(docCID),
        TxID:            ctx.GetStub().GetTxID(),
    }

    // update state
    st.OwnerUnitID = toOwnerUnitID
    st.LocationID = toLocationID
    // status rule: borrow -> borrowed; permanent -> active (remains active)
    if strings.EqualFold(transferType, "borrow") {
        st.Status = StatusBorrowed
    } else {
        st.Status = StatusActive
    }
    st.UpdatedAt = now
    sb, _ := json.Marshal(st)
    if err := ctx.GetStub().PutState(k, sb); err != nil { return nil, err }

    // write event log as state
    evKey := xferPrefixFor(assetID) + now
    lb, _ := json.Marshal(log)
    if err := ctx.GetStub().PutState(evKey, lb); err != nil { return nil, err }
    _ = ctx.GetStub().SetEvent("TransferAsset", lb)
    return log, nil
}

// UpdateMaintenance records maintenance and sets status to maintenance
func (c *AssetContract) UpdateMaintenance(ctx contractapi.TransactionContextInterface,
    assetID, date, mtype, note string, cost float64, technicianID, docCID string) (*MaintenanceLog, error) {

    k := assetKey(assetID)
    st, err := c.getAsset(ctx, k)
    if err != nil { return nil, err }

    // if date empty, use tx timestamp
    d := strings.TrimSpace(date)
    if d == "" { d = nowRFC3339(ctx) }

    log := &MaintenanceLog{
        AssetID:      assetID,
        Date:         d,
        Type:         mtype,
        Note:         note,
        Cost:         cost,
        TechnicianID: technicianID,
        DocCID:       strings.TrimSpace(docCID),
        TxID:         ctx.GetStub().GetTxID(),
    }

    st.Status = StatusMaintenance
    st.UpdatedAt = d
    sb, _ := json.Marshal(st)
    if err := ctx.GetStub().PutState(k, sb); err != nil { return nil, err }

    evKey := maintPrefixFor(assetID) + d
    lb, _ := json.Marshal(log)
    if err := ctx.GetStub().PutState(evKey, lb); err != nil { return nil, err }
    _ = ctx.GetStub().SetEvent("UpdateMaintenance", lb)
    return log, nil
}

// CompleteMaintenance sets asset status back to active and records a completion log
func (c *AssetContract) CompleteMaintenance(ctx contractapi.TransactionContextInterface,
    assetID, date, note string) (string, error) {

    k := assetKey(assetID)
    st, err := c.getAsset(ctx, k)
    if err != nil { return "", err }

    d := strings.TrimSpace(date)
    if d == "" { d = nowRFC3339(ctx) }

    log := &MaintenanceLog{AssetID: assetID, Date: d, Type: "complete", Note: note, Cost: 0, TxID: ctx.GetStub().GetTxID()}

    st.Status = StatusActive
    st.UpdatedAt = d
    sb, _ := json.Marshal(st)
    if err := ctx.GetStub().PutState(k, sb); err != nil { return "", err }

    evKey := maintPrefixFor(assetID) + d
    lb, _ := json.Marshal(log)
    if err := ctx.GetStub().PutState(evKey, lb); err != nil { return "", err }
    _ = ctx.GetStub().SetEvent("CompleteMaintenance", lb)
    return "OK", nil
}

// DisposeAsset marks an asset as disposed and records log
func (c *AssetContract) DisposeAsset(ctx contractapi.TransactionContextInterface,
    assetID, date, reason, docCID string) (*DisposeLog, error) {

    k := assetKey(assetID)
    st, err := c.getAsset(ctx, k)
    if err != nil { return nil, err }

    d := strings.TrimSpace(date)
    if d == "" { d = nowRFC3339(ctx) }

    log := &DisposeLog{
        AssetID: assetID,
        Date:    d,
        Reason:  reason,
        DocCID:  strings.TrimSpace(docCID),
        TxID:    ctx.GetStub().GetTxID(),
    }

    st.Status = StatusDisposed
    st.UpdatedAt = d
    sb, _ := json.Marshal(st)
    if err := ctx.GetStub().PutState(k, sb); err != nil { return nil, err }

    evKey := dispPrefixFor(assetID) + d
    lb, _ := json.Marshal(log)
    if err := ctx.GetStub().PutState(evKey, lb); err != nil { return nil, err }
    _ = ctx.GetStub().SetEvent("DisposeAsset", lb)
    return log, nil
}

// GetAsset returns the current state of an asset
func (c *AssetContract) GetAsset(ctx contractapi.TransactionContextInterface, assetID string) (*AssetState, error) {
    k := assetKey(assetID)
    return c.getAsset(ctx, k)
}

// GetAllAssets scans all asset states (prefixed by ASSET:)
func (c *AssetContract) GetAllAssets(ctx contractapi.TransactionContextInterface) ([]*AssetState, error) {
    start, end := prefixRange(keyAssetPrefix)
    iter, err := ctx.GetStub().GetStateByRange(start, end)
    if err != nil { return nil, err }
    defer iter.Close()
    var out []*AssetState
    for iter.HasNext() {
        kv, err := iter.Next()
        if err != nil { return nil, err }
        var st AssetState
        if err := json.Unmarshal(kv.Value, &st); err != nil { return nil, err }
        out = append(out, &st)
    }
    return out, nil
}

// GetAssetHistory returns a combined history from state changes and event logs
func (c *AssetContract) GetAssetHistory(ctx contractapi.TransactionContextInterface, assetID string) ([]*TimelineEvent, error) {
    var out []*TimelineEvent

    // State history
    hk := assetKey(assetID)
    histIter, err := ctx.GetStub().GetHistoryForKey(hk)
    if err == nil { // history may be disabled in some ledgers
        defer histIter.Close()
        for histIter.HasNext() {
            mod, err := histIter.Next()
            if err != nil { return nil, err }
            // Timestamp is part of mod.Timestamp (protobuf); use string fallback if needed
            var st AssetState
            if err := json.Unmarshal(mod.Value, &st); err != nil { return nil, err }
            // attempt formatting timestamp
            t := time.Unix(mod.Timestamp.Seconds, int64(mod.Timestamp.Nanos)).UTC().Format(time.RFC3339)
            pb, _ := json.Marshal(st)
            var m map[string]interface{}
            _ = json.Unmarshal(pb, &m)
            out = append(out, &TimelineEvent{Kind: "ASSET_STATE", Key: hk, Date: t, TxID: mod.TxId, Payload: m})
        }
    }

    // Transfer logs
    if evs, err := c.scanEvents(ctx, xferPrefixFor(assetID)); err == nil {
        out = append(out, evs...)
    }
    // Maintenance logs
    if evs, err := c.scanEvents(ctx, maintPrefixFor(assetID)); err == nil {
        out = append(out, evs...)
    }
    // Dispose logs
    if evs, err := c.scanEvents(ctx, dispPrefixFor(assetID)); err == nil {
        out = append(out, evs...)
    }

    return out, nil
}

func (c *AssetContract) scanEvents(ctx contractapi.TransactionContextInterface, prefix string) ([]*TimelineEvent, error) {
    start, end := prefixRange(prefix)
    iter, err := ctx.GetStub().GetStateByRange(start, end)
    if err != nil { return nil, err }
    defer iter.Close()
    var events []*TimelineEvent
    for iter.HasNext() {
        kv, err := iter.Next()
        if err != nil { return nil, err }
        kind := ""
        switch {
        case strings.HasPrefix(prefix, keyXferPrefix):
            kind = "TRANSFER"
        case strings.HasPrefix(prefix, keyMaintPrefix):
            kind = "MAINTENANCE"
        case strings.HasPrefix(prefix, keyDisposePrefix):
            kind = "DISPOSE"
        default:
            kind = "EVENT"
        }
        // date is the suffix after the prefix (e.g. "XFER:AST-IT-0001:2026-02-10T19:28:50Z")
        // Note: RFC3339 dates contain ':' so we cannot simply split by ':'
        date := strings.TrimPrefix(kv.Key, prefix)
        // parse payload and extract txId if present
        txid := ""
        var tmp map[string]interface{}
        if err := json.Unmarshal(kv.Value, &tmp); err == nil {
            if v, ok := tmp["txId"].(string); ok { txid = v }
        } else {
            tmp = map[string]interface{}{"raw": string(kv.Value)}
        }
        events = append(events, &TimelineEvent{Kind: kind, Key: kv.Key, Date: date, TxID: txid, Payload: tmp})
    }
    return events, nil
}

func (c *AssetContract) assetExists(ctx contractapi.TransactionContextInterface, key string) (bool, error) {
    b, err := ctx.GetStub().GetState(key)
    if err != nil {
        return false, err
    }
    return b != nil, nil
}

func (c *AssetContract) getAsset(ctx contractapi.TransactionContextInterface, key string) (*AssetState, error) {
    b, err := ctx.GetStub().GetState(key)
    if err != nil { return nil, err }
    if b == nil { return nil, fmt.Errorf("asset not found") }
    var st AssetState
    if err := json.Unmarshal(b, &st); err != nil { return nil, err }
    return &st, nil
}
