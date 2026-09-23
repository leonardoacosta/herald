package notify

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func benchmarkHistoryFixture(b *testing.B, count int) string {
	b.Helper()
	dir := b.TempDir()
	f, err := os.Create(filepath.Join(dir, historyFile))
	if err != nil {
		b.Fatal(err)
	}
	for i := 0; i < count; i++ {
		if _, err := fmt.Fprintf(f, `{"project":"bench","text":"record-%06d","voice":"kokoro:af_heart","outcome":"delivered"}`+"\n", i); err != nil {
			f.Close()
			b.Fatal(err)
		}
	}
	if err := f.Close(); err != nil {
		b.Fatal(err)
	}
	return dir
}

func BenchmarkHistoryCountAndTail10(b *testing.B) {
	for _, count := range []int{1_000, 10_000, 100_000} {
		dir := benchmarkHistoryFixture(b, count)
		b.Run(fmt.Sprintf("full-count/%d", count), func(b *testing.B) {
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				got, err := ReadHistory(dir)
				if err != nil || len(got) != count {
					b.Fatalf("ReadHistory count=(%d,%v), want (%d,nil)", len(got), err, count)
				}
			}
		})
		b.Run(fmt.Sprintf("full-tail10/%d", count), func(b *testing.B) {
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				all, err := ReadHistory(dir)
				if err != nil || len(all) != count {
					b.Fatalf("ReadHistory count=(%d,%v), want (%d,nil)", len(all), err, count)
				}
				tail := all[max(0, len(all)-10):]
				if len(tail) != min(count, 10) {
					b.Fatalf("full tail len=%d", len(tail))
				}
			}
		})
		b.Run(fmt.Sprintf("count/%d", count), func(b *testing.B) {
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				got, err := CountHistory(dir)
				if err != nil || got != count {
					b.Fatalf("CountHistory=(%d,%v), want (%d,nil)", got, err, count)
				}
			}
		})
		b.Run(fmt.Sprintf("tail10/%d", count), func(b *testing.B) {
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				got, err := TailHistory(dir, 10)
				if err != nil || len(got) != 10 {
					b.Fatalf("TailHistory=(%d,%v), want (10,nil)", len(got), err)
				}
			}
		})
	}
}

func TestCountAndTailScanCorruptionOutsideReturnedTail(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(HistoryPath(dir), []byte(`{"text":"a"}`+"\nnot-json\n"+`{"text":"c"}`+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := CountHistory(dir); err == nil {
		t.Fatal("CountHistory accepted corrupt interior row")
	}
	if _, err := TailHistory(dir, 1); err == nil {
		t.Fatal("TailHistory hid corrupt row before the requested tail")
	}
}

func TestTailHistoryOversizedNPreservesAllRecords(t *testing.T) {
	dir := t.TempDir()
	if err := AppendRecord(dir, Record{Text: "only", Outcome: OutcomeDelivered}); err != nil {
		t.Fatal(err)
	}
	got, err := TailHistory(dir, 100_001)
	if err != nil || len(got) != 1 || got[0].Text != "only" {
		t.Fatalf("TailHistory(100001)=(%v,%v), want one record", got, err)
	}
}
