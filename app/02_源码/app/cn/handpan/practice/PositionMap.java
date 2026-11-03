package cn.handpan.practice;

/* loaded from: classes.dex */
public final class PositionMap {
    public static void validate(int[] iArr) {
        if (iArr.length != 8) {
            throw new IllegalArgumentException("需要8个通道");
        }
        boolean[] zArr = new boolean[8];
        for (int i : iArr) {
            if (i < 0 || i > 7 || zArr[i]) {
                throw new IllegalArgumentException("CH0～7必须各出现一次");
            }
            zArr[i] = true;
        }
    }

    public static int channel(int[] iArr, int i) {
        return iArr[i];
    }
}
