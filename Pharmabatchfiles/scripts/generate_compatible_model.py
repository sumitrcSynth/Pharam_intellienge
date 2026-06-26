import json
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
import sklearn
import xgboost
from sklearn.compose import ColumnTransformer
from sklearn.impute import SimpleImputer
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OrdinalEncoder
from xgboost import XGBClassifier


CAT_COLS = ["PRODUCT_TYPE", "PLANT_ID", "BATCH_SIZE_BUCKET", "DURATION_BUCKET"]

NUM_COLS = [
    "TOTAL_TESTS",
    "FAILED_TESTS",
    "OOS_COUNT",
    "BORDERLINE_COUNT",
    "PASS_RATE_PCT",
    "OOS_RATE_PCT",
    "FAIL_RATE_PCT",
    "STERILITY_FAIL_FLAG",
    "ENDOTOXIN_FAIL_FLAG",
    "STERILITY_X_ENDOTOXIN",
    "TEMP_VIOLATION_COUNT",
    "TEMP_MAX_EXCURSION_MINS",
    "AVG_TEMP_DEVIATION_C",
    "HUMIDITY_VIOLATION_COUNT",
    "PRESSURE_VIOLATION_COUNT",
    "TOTAL_IOT_VIOLATIONS",
    "IOT_VIOLATION_DENSITY",
    "TEMP_X_DURATION",
    "TOTAL_DEVIATIONS",
    "CRITICAL_DEVIATION_COUNT",
    "HIGH_DEVIATION_COUNT",
    "WEIGHTED_DEVIATION_SCORE",
    "PROCESS_DEVIATION_COUNT",
    "EQUIPMENT_DEVIATION_COUNT",
    "HUMAN_DEVIATION_COUNT",
    "DEVIATION_DENSITY",
    "CRITICAL_DEV_RATE",
    "TEMP_X_CRITICAL_DEV",
    "BATCH_SIZE",
    "BATCH_DURATION_HOURS",
    "PROCESS_VARIANCE",
    "BATCH_START_HOUR",
    "BATCH_START_DOW",
    "IS_WEEKEND_BATCH",
    "IS_NIGHT_SHIFT",
]


def build_training_frame(rows: int = 900) -> tuple[pd.DataFrame, np.ndarray]:
    rng = np.random.default_rng(42)

    product_types = np.array(["Oral Solid", "Injection", "Vaccine", "Topical", "Biologic"])
    plants = np.array(["PLT-MUMBAI", "PLT-PUNE", "PLT-HYDERABAD", "PLT-AHMEDABAD"])
    size_buckets = np.array(["SMALL", "MEDIUM", "LARGE"])
    duration_buckets = np.array(["SHORT", "NORMAL", "LONG"])

    df = pd.DataFrame(
        {
            "PRODUCT_TYPE": rng.choice(product_types, rows),
            "PLANT_ID": rng.choice(plants, rows),
            "BATCH_SIZE_BUCKET": rng.choice(size_buckets, rows, p=[0.25, 0.5, 0.25]),
            "DURATION_BUCKET": rng.choice(duration_buckets, rows, p=[0.2, 0.6, 0.2]),
        }
    )

    df["TOTAL_TESTS"] = rng.integers(12, 42, rows)
    df["FAILED_TESTS"] = rng.binomial(df["TOTAL_TESTS"], rng.uniform(0.02, 0.18, rows))
    df["OOS_COUNT"] = rng.binomial(df["FAILED_TESTS"], 0.45)
    df["BORDERLINE_COUNT"] = rng.poisson(1.5, rows)
    df["PASS_RATE_PCT"] = np.clip(100 * (df["TOTAL_TESTS"] - df["FAILED_TESTS"]) / df["TOTAL_TESTS"], 0, 100)
    df["OOS_RATE_PCT"] = np.clip(100 * df["OOS_COUNT"] / df["TOTAL_TESTS"], 0, 100)
    df["FAIL_RATE_PCT"] = np.clip(100 * df["FAILED_TESTS"] / df["TOTAL_TESTS"], 0, 100)

    df["STERILITY_FAIL_FLAG"] = rng.binomial(1, 0.08, rows)
    df["ENDOTOXIN_FAIL_FLAG"] = rng.binomial(1, 0.07, rows)
    df["STERILITY_X_ENDOTOXIN"] = df["STERILITY_FAIL_FLAG"] * df["ENDOTOXIN_FAIL_FLAG"]

    df["TEMP_VIOLATION_COUNT"] = rng.poisson(1.2, rows)
    df["TEMP_MAX_EXCURSION_MINS"] = np.clip(rng.gamma(2.0, 7.0, rows), 0, 90)
    df["AVG_TEMP_DEVIATION_C"] = np.clip(rng.normal(0.8, 0.7, rows), 0, 5)
    df["HUMIDITY_VIOLATION_COUNT"] = rng.poisson(0.6, rows)
    df["PRESSURE_VIOLATION_COUNT"] = rng.poisson(0.4, rows)
    df["TOTAL_IOT_VIOLATIONS"] = (
        df["TEMP_VIOLATION_COUNT"] + df["HUMIDITY_VIOLATION_COUNT"] + df["PRESSURE_VIOLATION_COUNT"]
    )
    df["BATCH_DURATION_HOURS"] = np.clip(rng.normal(28, 8, rows), 8, 72)
    df["IOT_VIOLATION_DENSITY"] = df["TOTAL_IOT_VIOLATIONS"] / df["BATCH_DURATION_HOURS"]
    df["TEMP_X_DURATION"] = df["TEMP_VIOLATION_COUNT"] * df["BATCH_DURATION_HOURS"]

    df["TOTAL_DEVIATIONS"] = rng.poisson(2.0, rows)
    df["CRITICAL_DEVIATION_COUNT"] = rng.binomial(df["TOTAL_DEVIATIONS"], 0.16)
    df["HIGH_DEVIATION_COUNT"] = rng.binomial(df["TOTAL_DEVIATIONS"], 0.25)
    df["WEIGHTED_DEVIATION_SCORE"] = (
        df["CRITICAL_DEVIATION_COUNT"] * 5 + df["HIGH_DEVIATION_COUNT"] * 3 + df["TOTAL_DEVIATIONS"]
    )
    df["PROCESS_DEVIATION_COUNT"] = rng.binomial(df["TOTAL_DEVIATIONS"], 0.35)
    df["EQUIPMENT_DEVIATION_COUNT"] = rng.binomial(df["TOTAL_DEVIATIONS"], 0.3)
    df["HUMAN_DEVIATION_COUNT"] = rng.binomial(df["TOTAL_DEVIATIONS"], 0.2)
    df["DEVIATION_DENSITY"] = df["TOTAL_DEVIATIONS"] / np.maximum(df["BATCH_DURATION_HOURS"], 1)
    df["CRITICAL_DEV_RATE"] = df["CRITICAL_DEVIATION_COUNT"] / np.maximum(df["TOTAL_DEVIATIONS"], 1)
    df["TEMP_X_CRITICAL_DEV"] = df["TEMP_VIOLATION_COUNT"] * df["CRITICAL_DEVIATION_COUNT"]

    df["BATCH_SIZE"] = np.where(df["BATCH_SIZE_BUCKET"] == "SMALL", 1200, np.where(df["BATCH_SIZE_BUCKET"] == "MEDIUM", 3000, 6000))
    df["BATCH_SIZE"] = df["BATCH_SIZE"] + rng.normal(0, 250, rows)
    df["PROCESS_VARIANCE"] = np.clip(rng.normal(0.08, 0.05, rows), 0, 0.35)
    df["BATCH_START_HOUR"] = rng.integers(0, 24, rows)
    df["BATCH_START_DOW"] = rng.integers(0, 7, rows)
    df["IS_WEEKEND_BATCH"] = (df["BATCH_START_DOW"] >= 5).astype(int)
    df["IS_NIGHT_SHIFT"] = ((df["BATCH_START_HOUR"] < 6) | (df["BATCH_START_HOUR"] >= 22)).astype(int)

    risk_score = (
        0.035 * df["FAIL_RATE_PCT"]
        + 0.060 * df["OOS_RATE_PCT"]
        + 0.850 * df["STERILITY_FAIL_FLAG"]
        + 0.750 * df["ENDOTOXIN_FAIL_FLAG"]
        + 0.090 * df["TEMP_VIOLATION_COUNT"]
        + 0.060 * df["TOTAL_DEVIATIONS"]
        + 0.180 * df["CRITICAL_DEVIATION_COUNT"]
        + 0.500 * df["PROCESS_VARIANCE"]
        + 0.120 * df["IS_NIGHT_SHIFT"]
        + rng.normal(0, 0.35, rows)
    )
    y = (risk_score > np.quantile(risk_score, 0.58)).astype(int)
    return df[CAT_COLS + NUM_COLS], y


def main() -> None:
    assert sklearn.__version__ == "1.3.0", f"Expected scikit-learn 1.3.0, got {sklearn.__version__}"
    assert np.__version__.startswith("1.26."), f"Expected NumPy 1.26.x, got {np.__version__}"

    x, y = build_training_frame()

    preprocessor = ColumnTransformer(
        [
            (
                "cat",
                Pipeline(
                    [
                        ("imputer", SimpleImputer(strategy="constant", fill_value="UNKNOWN")),
                        (
                            "encoder",
                            OrdinalEncoder(
                                handle_unknown="use_encoded_value",
                                unknown_value=-1,
                                encoded_missing_value=-1,
                            ),
                        ),
                    ]
                ),
                CAT_COLS,
            ),
            ("num", Pipeline([("imputer", SimpleImputer(strategy="median"))]), NUM_COLS),
        ],
        remainder="drop",
    )

    neg_count = int((y == 0).sum())
    pos_count = int((y == 1).sum())
    model = Pipeline(
        [
            ("prep", preprocessor),
            (
                "model",
                XGBClassifier(
                    n_estimators=160,
                    max_depth=4,
                    learning_rate=0.06,
                    subsample=0.85,
                    colsample_bytree=0.85,
                    min_child_weight=2,
                    gamma=0.05,
                    reg_alpha=0.02,
                    reg_lambda=1.0,
                    scale_pos_weight=float(neg_count) / max(float(pos_count), 1.0),
                    objective="binary:logistic",
                    eval_metric="auc",
                    random_state=42,
                    n_jobs=1,
                ),
            ),
        ]
    )
    model.fit(x, y)

    out_dir = Path(__file__).resolve().parents[1] / "artifacts"
    out_dir.mkdir(exist_ok=True)
    model_path = out_dir / "pharma_batch_model.pkl"
    meta_path = out_dir / "pharma_model_meta.json"

    joblib.dump(model, model_path, compress=0, protocol=4)
    meta_path.write_text(
        json.dumps(
            {
                "cat_cols": CAT_COLS,
                "num_cols": NUM_COLS,
                "all_cols": CAT_COLS + NUM_COLS,
                "target": "TARGET_BINARY",
                "training_source": "scripts/generate_compatible_model.py deterministic synthetic pharma batch training set",
                "python_version_note": "Serialized with Python 3.10 using Snowflake-compatible package versions.",
                "numpy_version": np.__version__,
                "joblib_version": joblib.__version__,
                "sklearn_version": sklearn.__version__,
                "xgboost_version": xgboost.__version__,
                "rows": int(len(x)),
                "positive_rows": pos_count,
                "negative_rows": neg_count,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"Wrote {model_path}")
    print(f"Wrote {meta_path}")


if __name__ == "__main__":
    main()
