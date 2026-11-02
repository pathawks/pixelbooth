/// <summary>
/// Compare simple chroma interpolation models while fitting the color matrix.
/// A lower score is evidence about a particular Windows conversion path only;
/// reconstruction filters and other camera processing can affect the score.
/// </summary>
internal static class Yuy2ChromaFit
{
    public enum Model { Nearest, CositedLinear, CenteredLinear }
    public readonly record struct Result(double Error, int Count);

    public static Result? Score(byte[] yuy2, byte[] bgra, int width, int height, Model model, bool edgesOnly)
    {
        if (width < 8 || (width & 1) != 0 || height < 1 ||
            yuy2.Length != checked(width * height * 2) || bgra.Length != checked(width * height * 4))
            throw new ArgumentException("Unexpected frame size for chroma comparison.");

        // Solve three independent least-squares problems for B, G and R. Normalize
        // channel values to keep the fixed-size normal equations well conditioned.
        var normal = new double[3, 4, 4];
        var rhs = new double[3, 4];
        var used = new int[3];
        Visit((features, target, channel) =>
        {
            used[channel]++;
            for (var i = 0; i < 4; i++)
            {
                rhs[channel, i] += features[i] * target;
                for (var j = 0; j < 4; j++) normal[channel, i, j] += features[i] * features[j];
            }
        });
        var coefficients = new double[3][];
        for (var c = 0; c < 3; c++)
        {
            if (used[c] < 100) return null;
            var solution = Solve(normal, rhs, c);
            if (solution is null) return null;
            coefficients[c] = solution;
        }
        double squared = 0;
        Visit((features, target, channel) =>
        {
            double predicted = 0;
            for (var i = 0; i < 4; i++) predicted += coefficients[channel][i] * features[i];
            squared += (target - predicted) * (target - predicted);
        });
        var count = used.Sum();
        return new Result(Math.Sqrt(squared / count), count);

        void Visit(Action<double[], double, int> visit)
        {
            var features = new double[4];
            features[3] = 1;
            for (var row = 0; row < height; row++)
            for (var x = 2; x < width - 2; x++)
            {
                var pair = row * width * 2 + (x / 2) * 4;
                var u = yuy2[pair + 1]; var v = yuy2[pair + 3];
                var up = yuy2[pair - 3]; var vp = yuy2[pair - 1];
                var un = yuy2[pair + 5]; var vn = yuy2[pair + 7];
                if (edgesOnly && Math.Abs(u - up) + Math.Abs(u - un) + Math.Abs(v - vp) + Math.Abs(v - vn) < 16) continue;
                var weight = model == Model.Nearest || (model == Model.CositedLinear && x % 2 == 0) ? 0 :
                    model == Model.CositedLinear ? .5 : .25;
                var adjacentU = x % 2 == 0 ? up : un;
                var adjacentV = x % 2 == 0 ? vp : vn;
                features[0] = (yuy2[pair + (x % 2) * 2] - 128) / 128.0;
                features[1] = ((u * (1 - weight) + adjacentU * weight) - 128) / 128.0;
                features[2] = ((v * (1 - weight) + adjacentV * weight) - 128) / 128.0;
                var offset = (row * width + x) * 4;
                for (var c = 0; c < 3; c++)
                    if (bgra[offset + c] is > 2 and < 253) visit(features, bgra[offset + c], c);
            }
        }
    }

    private static double[]? Solve(double[,,] normal, double[,] rhs, int channel)
    {
        var a = new double[4, 5];
        for (var i = 0; i < 4; i++)
        {
            for (var j = 0; j < 4; j++) a[i, j] = normal[channel, i, j];
            a[i, 4] = rhs[channel, i];
        }
        for (var i = 0; i < 4; i++)
        {
            var pivot = i;
            for (var row = i + 1; row < 4; row++) if (Math.Abs(a[row, i]) > Math.Abs(a[pivot, i])) pivot = row;
            if (Math.Abs(a[pivot, i]) < 1e-8) return null;
            if (pivot != i) for (var j = i; j < 5; j++) (a[i, j], a[pivot, j]) = (a[pivot, j], a[i, j]);
            var divisor = a[i, i];
            for (var j = i; j < 5; j++) a[i, j] /= divisor;
            for (var row = 0; row < 4; row++)
            {
                if (row == i) continue;
                var factor = a[row, i];
                for (var j = i; j < 5; j++) a[row, j] -= factor * a[i, j];
            }
        }
        return [a[0, 4], a[1, 4], a[2, 4], a[3, 4]];
    }
}
