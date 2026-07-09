#!/usr/bin/env python3
"""Generate a synthetic multi-slice CT series for imaging-overhaul P1 testing.

Takes the real single 512x512 head-CT instance
(`scenarios/2025-03-12_头颅CT_协和.dcm`) and derives ~12 slices that share one
StudyInstanceUID + SeriesInstanceUID with incrementing InstanceNumber and a
stepped ImagePositionPatient. Identical pixels are fine here: the goal is to
verify the STACK MODEL (grouping N .dcm into one scrollable study), not to
produce anatomically-varied slices. Real varied series come later.

    python3 examples/demo-dataset/gen_ct_series.py

Writes to examples/demo-dataset/imaging/头颅CT序列/slice_XX.dcm.
Requires: pydicom.
"""
import os
import pydicom

N_SLICES = 12
HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "scenarios", "2025-03-12_头颅CT_协和.dcm")
OUT_DIR = os.path.join(HERE, "imaging", "头颅CT序列")


def main() -> None:
    ds = pydicom.dcmread(SRC)
    # One shared study + series for all slices — this is what groups them.
    study_uid = ds.StudyInstanceUID
    series_uid = ds.SeriesInstanceUID
    os.makedirs(OUT_DIR, exist_ok=True)

    # Base image position; step 5mm along Z per slice (typical CT spacing).
    try:
        base_pos = [float(x) for x in ds.ImagePositionPatient]
    except Exception:
        base_pos = [0.0, 0.0, 0.0]

    for i in range(1, N_SLICES + 1):
        slc = ds.copy()
        slc.StudyInstanceUID = study_uid
        slc.SeriesInstanceUID = series_uid
        slc.InstanceNumber = str(i)
        slc.SeriesNumber = ds.get("SeriesNumber", "4")
        # Each instance MUST have a unique SOPInstanceUID.
        slc.SOPInstanceUID = f"{series_uid}.{i}"
        if hasattr(slc, "file_meta") and hasattr(slc.file_meta, "MediaStorageSOPInstanceUID"):
            slc.file_meta.MediaStorageSOPInstanceUID = slc.SOPInstanceUID
        slc.ImagePositionPatient = [base_pos[0], base_pos[1], base_pos[2] + (i - 1) * 5.0]
        slc.SliceLocation = str(base_pos[2] + (i - 1) * 5.0)
        out = os.path.join(OUT_DIR, f"slice_{i:02d}.dcm")
        slc.save_as(out)
        print(f"wrote {out}")

    print(f"\n{N_SLICES} slices, StudyInstanceUID={study_uid}")


if __name__ == "__main__":
    main()
