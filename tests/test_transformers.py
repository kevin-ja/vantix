import pickle

import numpy as np

from pipelines.common.transformers import Winsorizer, build_preprocessor


def test_winsorizer_learns_bounds_in_fit_only():
    train = np.arange(101, dtype=float).reshape(-1, 1)
    w = Winsorizer(0.01, 0.99).fit(train)
    # transform usa los límites aprendidos, no los recalcula sobre los datos nuevos
    out = w.transform(np.array([[-1000.0], [50.0], [1000.0]]))
    np.testing.assert_allclose(out.ravel(), [1.0, 50.0, 99.0])


def test_preprocessor_roundtrip_pickle():
    rng = np.random.default_rng(0)
    X = rng.lognormal(size=(500, 5))
    pre = build_preprocessor()
    Xt = pre.fit_transform(X)
    assert Xt.min() >= 0 and Xt.max() <= 1

    loaded = pickle.loads(pickle.dumps(pre))
    X_new = rng.lognormal(size=(20, 5))
    np.testing.assert_allclose(loaded.transform(X_new), pre.transform(X_new))
