interface IssueFormProps {
  userId: string;
  onUserIdChange: (value: string) => void;
  onIssue: () => void;
  isIssuing: boolean;
  remaining: number;
  feedback: { type: 'success' | 'error'; text: string } | null;
}

export function IssueForm({
  userId,
  onUserIdChange,
  onIssue,
  isIssuing,
  remaining,
  feedback,
}: IssueFormProps) {
  const isSoldOut = remaining <= 0;
  const isDisabled = isIssuing || isSoldOut;

  return (
    <section className="rounded-xl border border-gray-200 bg-white p-5 shadow-sm dark:border-gray-700 dark:bg-gray-800">
      <h2 className="mb-4 text-lg font-semibold text-gray-900 dark:text-gray-100">
        쿠폰 발급
      </h2>

      <label className="mb-4 block text-sm font-medium text-gray-700 dark:text-gray-300">
        사용자 ID
        <input
          type="text"
          value={userId}
          onChange={(e) => onUserIdChange(e.target.value)}
          disabled={isIssuing}
          className="mt-1 w-full rounded-md border border-gray-300 px-3 py-2 text-sm text-gray-900 focus:border-indigo-500 focus:ring-2 focus:ring-indigo-500 focus:outline-none disabled:bg-gray-100 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-100 dark:disabled:bg-gray-800"
        />
      </label>

      <button
        type="button"
        onClick={onIssue}
        disabled={isDisabled}
        className={`flex w-full items-center justify-center gap-2 rounded-md py-2.5 text-sm font-semibold text-white transition ${
          isDisabled
            ? 'cursor-not-allowed bg-gray-300 dark:bg-gray-600'
            : 'bg-indigo-600 hover:bg-indigo-700'
        }`}
      >
        {isIssuing && (
          <span className="h-4 w-4 animate-spin rounded-full border-2 border-white/60 border-t-white" />
        )}
        {isSoldOut ? '마감되었습니다' : isIssuing ? '발급 중...' : '쿠폰 받기'}
      </button>

      {feedback && (
        <p
          className={`mt-3 rounded-md border px-3 py-2 text-sm ${
            feedback.type === 'success'
              ? 'border-green-200 bg-green-50 text-green-700'
              : 'border-red-200 bg-red-50 text-red-700'
          }`}
        >
          {feedback.text}
        </p>
      )}
    </section>
  );
}
