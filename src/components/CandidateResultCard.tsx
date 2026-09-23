import React from 'react';

interface CandidateResultCardProps {
  candidateName: string;
  candidatePhotoUrl: string;
  partyName: string;
  partyLogoUrl: string;
  votesCount: number;
  percentage: number;
  primaryColor?: string;
}

const CandidateResultCard: React.FC<CandidateResultCardProps> = ({
  candidateName,
  candidatePhotoUrl,
  partyName,
  partyLogoUrl,
  votesCount,
  percentage,
  primaryColor = '#003366',
}) => {
  // Format votes count with thousand separators (US style)
  const formattedVotes = votesCount.toLocaleString('en-US', {
    minimumFractionDigits: 0,
    maximumFractionDigits: 0,
  });

  // Calculate SVG stroke values for the progress ring
  const radius = 35;
  const circumference = 2 * Math.PI * radius;
  const visibleLength = (percentage / 100) * circumference;

  return (
    <div className="flex w-[300px] bg-white rounded-xl shadow-md p-4 space-x-4">
      {/* Left Side: Circular Progress + Photo */}
      <div className="relative w-[80px] h-[80px] flex-shrink-0">
        <svg width="80" height="80" className="block">
          {/* Background ring */}
          <circle
            cx="40"
            cy="40"
            r="35"
            stroke="#E5E7EB"
            strokeWidth="10"
            fill="none"
          />
          {/* Progress ring */}
          <circle
            cx="40"
            cy="40"
            r="35"
            stroke={primaryColor}
            strokeWidth="10"
            fill="none"
            strokeDasharray={`${visibleLength} 1000`}
            transform="rotate(-90 40 40)"
          />
        </svg>
        {/* Candidate Photo */}
        <img
          src={candidatePhotoUrl}
          alt={candidateName}
          className="absolute inset-[20%] rounded-full object-cover z-10"
        />
      </div>

      {/* Right Side: Electoral Data */}
      <div className="flex-1 space-y-2">
        {/* Percentage of Votes */}
        <div className="text-5xl font-extrabold text-[#003366]">
          {percentage.toFixed(3)} %
        </div>

        {/* Divider */}
        <div className="h-0.5 w-16 bg-gray-200"></div>

        {/* Candidate Name */}
        <p className="text-lg font-bold text-[#003366] uppercase">
          {candidateName.toUpperCase()}
        </p>

        {/* Political Party Row */}
        <div className="flex items-center gap-2">
          <img
            src={partyLogoUrl}
            alt={partyName}
            className="w-6 h-6 rounded-full object-cover"
          />
          <span className="text-xs font-semibold text-gray-600 uppercase">
            {partyName}
          </span>
        </div>

        {/* Total Votes */}
        <p className="text-sm font-semibold text-[#003366]">
          {formattedVotes} votos
        </p>
      </div>
    </div>
  );
};

export default CandidateResultCard;