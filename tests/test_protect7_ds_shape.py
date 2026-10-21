"""Protect 7.x Device Service ("ds") message shape.

Protect 7 moved camera handling into /usr/bin/ds, a Rust service that
deserialises every avclient message into strict structs before deciding
whether to handle it. Anything it cannot parse is forwarded, untouched, to
the legacy Node service, which then logs

    Received EventSmartDetect over avclient which was not expected to be
    received; DS should handle this message

and drops it. These tests pin the fields a real G4/G5 camera sends (traced
on Protect 7.3.70 with ds's own payload logging) so the proxy keeps
parsing there: the envelope's timeStamp/statusCode, zonesStatus.level,
the descriptor field set, and null (not {}) for the optional maps.
"""

import argparse
import json
import re

import pytest

from unifi.cams.rtsp import RTSPCam

REAL_DESCRIPTOR_KEYS = {
    # from a G4 Doorbell's EventSmartDetect, Protect 7.3.70
    "id", "objectType", "attributes", "boxColor", "confidenceLevel", "depth",
    "speed", "timestamp", "duration", "coord", "coord3d", "firstShownTimeMs",
    "idleSinceTimeMs", "lines", "loiterZones", "name", "licensePlate",
    "matchedId", "secondLensZones", "stationary", "tag", "trackerID", "zones",
    "intelligenceZones", "associatedFaceTrackerID", "faceEmbed",
}


@pytest.fixture
def cam():
    cam = RTSPCam.__new__(RTSPCam)
    cam.args = argparse.Namespace(mac="AABBCC001274")
    cam._msg_id = 0
    cam.gen_msg_id = lambda: 1
    return cam


def test_envelope_has_timestamp_and_status_code(cam):
    msg = cam.gen_response("EventSmartDetect", payload={"x": 1})
    assert msg["statusCode"] == 0
    # 2026-10-20T23:32:58.383+00:00 — what a real camera sends
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}\+00:00", msg["timeStamp"])
    assert msg["to"] == "UniFiVideo" and msg["from"] == "ubnt_avclient"
    json.dumps(msg)  # serialisable


def test_descriptor_matches_real_camera_field_set(cam):
    d = cam.build_smart_descriptor("person", [250, 250, 500, 500], 0.9, 100)
    assert REAL_DESCRIPTOR_KEYS <= set(d)
    # ds parses a non-null `attributes` as a full attribute struct: send null
    assert d["attributes"] is None
    assert d["coord3d"] == [-1, -1]
    assert all(isinstance(c, int) for c in d["coord"])
    assert d["trackerID"] == 100 and d["confidenceLevel"] == 90
    assert d["firstShownTimeMs"] <= d["timestamp"]


def test_first_shown_is_stable_per_tracker_and_reset_on_leave(cam):
    a = cam.build_smart_descriptor("person", [0, 0, 10, 10], 0.9, 7)
    b = cam.build_smart_descriptor("person", [5, 5, 10, 10], 0.9, 7)
    assert a["firstShownTimeMs"] == b["firstShownTimeMs"]
    cam._ds_payload_fill({"edgeType": "leave"})
    assert cam._ds_first_seen == {}


def test_payload_fill_adds_zone_level_and_null_maps(cam):
    payload = {
        "edgeType": "enter",
        "zonesStatus": {"1": {"status": "enter"}},
        "descriptors": [],
    }
    cam._ds_payload_fill(payload)
    assert payload["zonesStatus"]["1"] == {"status": "enter", "level": 0}
    # null, not {}: a non-null linesStatus makes ds file the event as a
    # line-crossing (smartDetectLine) instead of a zone detection
    for k in ("linesStatus", "loiterZonesStatus", "intelligenceZonesStatus", "tamperStatus", "trackerIDAttrMap"):
        assert payload[k] is None, k
    assert payload["smartDetectSnapshots"] == []
    assert payload["smartDetectSnapshotFullFoVHeight"] == 0


def test_payload_fill_keeps_existing_values(cam):
    payload = {"edgeType": "leave", "zonesStatus": {"1": {"status": "leave", "level": 5}},
               "trackerIDAttrMap": {"9": {}}, "smartDetectSnapshots": [{"a": 1}]}
    cam._ds_payload_fill(payload)
    assert payload["zonesStatus"]["1"]["level"] == 5
    assert payload["trackerIDAttrMap"] == {"9": {}}
    assert payload["smartDetectSnapshots"] == [{"a": 1}]


def test_motion_box_finds_changed_region(cam):
    w, h = cam._MOTION_W, cam._MOTION_H
    before = bytes([0] * (w * h))
    after = bytearray(before)
    for y in range(10, 20):
        for x in range(30, 40):
            after[y * w + x] = 200
    n, box = cam._motion_box(before, bytes(after))
    assert n == 100 and box == (30, 10, 39, 19)


def test_motion_box_ignores_stray_noise_pixels(cam):
    w, h = cam._MOTION_W, cam._MOTION_H
    before = bytes([0] * (w * h))
    after = bytearray(before)
    for y in range(50, 60):
        for x in range(100, 110):
            after[y * w + x] = 200
    after[0] = 200  # one noisy pixel in the far corner
    n, box = cam._motion_box(before, bytes(after))
    assert n == 101 and box == (100, 50, 109, 59)


def test_motion_box_ignores_small_noise(cam):
    w, h = cam._MOTION_W, cam._MOTION_H
    before = bytes([100] * (w * h))
    after = bytes([112] * (w * h))  # 12 levels of lighting change: under threshold
    n, _ = cam._motion_box(before, after)
    assert n == 0
