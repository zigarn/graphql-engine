import { One_Click_Deployment_States_Enum } from '@/features/ControlPlane';

export type UserOnboarding = {
  activity: Record<string, any>;
  target: string;
};

export type User = {
  id: string;
  created_at: string;
};

export type OneClickDeploymentByProject = {
  id: number;
  state: One_Click_Deployment_States_Enum;
  git_repository_url: string;
  git_repository_branch?: string;
  hasura_directory?: string;
};

export type OnboardingResponseData = {
  data: {
    user_onboarding: UserOnboarding[];
    users: User[];
    one_click_deployment: OneClickDeploymentByProject[];
  };
};
