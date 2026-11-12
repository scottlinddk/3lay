import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("evaluation", Path(__file__).with_name("evaluate-scan-coach.py"))
evaluation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evaluation)


def trial(pair, condition, **values):
    return dict(pair=pair, condition=condition, **{
        "success": True, "captureSeconds": 100, "dimensionErrorMM": 2,
        "holes": 1, "peakMemoryMB": 800, "seriousThermal": False,
        "adviceCount": 0, "unsupportedAdviceCount": 0, "inferenceMilliseconds": 0, **values})


class EvaluationTests(unittest.TestCase):
    def test_paired_deltas_exclude_missing_pairs(self):
        result = evaluation.summarize([
            trial("a", "baseline"), trial("a", "coach", captureSeconds=80, dimensionErrorMM=1),
            trial("b", "coach")])
        self.assertEqual(result["completePairs"], 1)
        self.assertEqual(result["excludedIncompletePairs"], 1)
        self.assertEqual(result["medianPairedDeltaCoachMinusBaseline"]["captureSeconds"]["delta"], -20)

    def test_failures_count_in_success_rate_not_geometry_metrics(self):
        result = evaluation.summarize([
            trial("a", "baseline"), trial("a", "coach", success=False, dimensionErrorMM=None)])
        self.assertEqual(result["coach"]["successRate"], 0)
        self.assertIsNone(result["medianPairedDeltaCoachMinusBaseline"]["dimensionErrorMM"]["delta"])
        self.assertEqual(result["medianPairedDeltaCoachMinusBaseline"]["holes"]["pairs"], 0)

    def test_rejects_duplicates_and_invalid_numbers(self):
        for rows in ([trial("a", "baseline"), trial("a", "baseline")],
                     [trial("a", "coach", peakMemoryMB=float("nan"))],
                     [trial("a", "coach", adviceCount=0, unsupportedAdviceCount=1)]):
            with self.assertRaises(ValueError):
                evaluation.summarize(rows)


if __name__ == "__main__":
    unittest.main()
